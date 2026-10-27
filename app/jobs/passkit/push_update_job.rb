module Passkit
  # Sends the pass update push for a batch of passes (Passkit::Push). A
  # transient failure is retried for the devices still owed a push only, with
  # a growing wait, up to MAX_ATTEMPTS; then it is reported and dropped (the
  # next change pushes again). A fatal APNs error (certificate, topic) is
  # reported and not retried: every push would fail the same way.
  class PushUpdateJob < ActiveJob::Base
    queue_as :default

    MAX_ATTEMPTS = 5

    discard_on(Passkit::PushFatalError) { |_job, error| Rails.error.report(error, handled: true) }

    def perform(pass_ids, device_ids = nil, attempt = 1)
      # The switch can be turned off after the job was queued.
      return unless Passkit.configuration&.push_enabled

      Passkit::Push.new.call(pass_ids, device_ids: device_ids)
    rescue Passkit::PushError => e
      if attempt >= MAX_ATTEMPTS
        Rails.error.report(e, handled: true)
      else
        self.class.set(wait: ((attempt**4) + 5).seconds).perform_later(pass_ids, e.failed_device_ids, attempt + 1)
      end
    end
  end
end
