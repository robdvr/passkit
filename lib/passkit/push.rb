require "apnotic"

module Passkit
  # Tells Wallet that passes changed, per Apple's update protocol: one push
  # to every device token registered for the passes, signed with the pass
  # type certificate that signs the passes, topic = the pass type
  # identifier, payload an empty JSON dictionary, production APNs only (pass
  # updates don't work on the sandbox). Wallet then asks the web service
  # which serials changed and fetches each one.
  #
  # A device whose token APNs rejects is removed, as Apple asks. Transient
  # failures (timeouts, 429, 5xx) are counted and raised as a PushError once
  # every device was tried, so a job can retry; a certificate or topic error
  # stops at once, because every push would fail the same way.
  class Push
    PRODUCTION_URL = "https://api.push.apple.com:443"
    EMPTY_PAYLOAD = "{}"
    # APNs reasons that mean the token itself is dead.
    INVALID_TOKEN_REASONS = %w[BadDeviceToken DeviceTokenNotForTopic Unregistered ExpiredToken].freeze
    TRANSIENT_STATUSES = %w[429 500 503].freeze
    TIMEOUT_SECONDS = 15

    Result = Struct.new(:sent, :removed)

    # An update push: Apple's payload is `{}`, not apnotic's `{"aps": {}}`.
    class Notification < Apnotic::AbstractNotification
      def body
        EMPTY_PAYLOAD.dup.force_encoding(Encoding::BINARY)
      end

      private

      def to_hash
        {}
      end
    end

    def initialize(connection: nil)
      @connection = connection
    end

    def call(pass_ids)
      devices = Passkit::Device
        .where(id: Passkit::Registration.where(passkit_pass_id: pass_ids).select(:passkit_device_id))
        .where.not(push_token: [nil, ""])
        .to_a
      return Result.new(sent: 0, removed: 0) if devices.empty?

      sent = 0
      removed = 0
      transient = []
      connection = @connection || build_connection
      begin
        devices.each do |device|
          response = connection.push(notification_for(device), timeout: TIMEOUT_SECONDS)
          case outcome(response)
          when :sent then sent += 1
          when :invalid_token
            remove(device)
            removed += 1
          when :transient then transient << describe(response)
          else
            raise PushError, "APNs refused the pass update push: #{describe(response)}"
          end
        end
      ensure
        connection.close
      end

      if transient.any?
        raise PushError, "#{transient.size} of #{devices.size} pass update pushes failed: #{transient.uniq.join(", ")}"
      end

      Result.new(sent: sent, removed: removed)
    end

    private

    def build_connection
      config = Passkit.configuration
      Apnotic::Connection.new(
        cert_path: Rails.root.join(config.private_p12_certificate).to_s,
        cert_pass: config.certificate_key,
        url: PRODUCTION_URL
      )
    end

    def notification_for(device)
      Notification.new(device.push_token).tap do |notification|
        notification.topic = Passkit.configuration.pass_type_identifier
        notification.push_type = Passkit.configuration.push_type
      end
    end

    def outcome(response)
      return :transient if response.nil?
      return :sent if response.ok?
      return :invalid_token if response.status == "410" || INVALID_TOKEN_REASONS.include?(reason(response))
      return :transient if TRANSIENT_STATUSES.include?(response.status)
      :fatal
    end

    def reason(response)
      body = response.body
      body.is_a?(Hash) ? body["reason"] : nil
    end

    def describe(response)
      return "no response (timeout)" if response.nil?
      [response.status, reason(response)].compact.join(" ")
    end

    def remove(device)
      Passkit::Device.transaction do
        Passkit::Registration.where(passkit_device_id: device.id).delete_all
        device.destroy!
      end
    end
  end
end
