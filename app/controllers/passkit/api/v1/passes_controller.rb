module Passkit
  module Api
    module V1
      class PassesController < ActionController::API
        before_action :decrypt_payload, only: :create
        before_action :set_generator, only: :create

        def create
          if @generator && @payload[:collection_name].present?
            collection_name = validated_collection_name(@generator, @payload[:collection_name])
            return head(:not_found) unless collection_name

            files = @generator.public_send(collection_name).collect do |collection_item|
              Passkit::Factory.create_pass(@payload[:pass_class], collection_item)
            end
            file = Passkit::Generator.compress_passes_files(files)
            send_file(file, type: "application/vnd.apple.pkpasses", disposition: "attachment")
          else
            file = Passkit::Factory.create_pass(@payload[:pass_class], @generator)
            send_file(file, type: "application/vnd.apple.pkpass", disposition: "attachment")
          end
        end

        # @return If request is authorized, returns HTTP status 200 with a payload of the pass data.
        # @return If the request is not authorized, returns HTTP status 401.
        # @return Otherwise, returns the appropriate standard HTTP status.
        def show
          authentication_token = request.headers["Authorization"]&.split(" ")&.last
          unless authentication_token.present?
            render json: {}, status: :unauthorized
            return
          end

          pass = Pass.find_by(serial_number: params[:serial_number], authentication_token: authentication_token)
          unless pass
            render json: {}, status: :unauthorized
            return
          end

          pass_output_path = Passkit::Generator.new(pass).generate_and_sign

          response.headers["last-modified"] = pass.last_update.httpdate
          modified_since = parse_time(request.headers["If-Modified-Since"])
          if modified_since.nil? || pass.last_update.to_i > modified_since.to_i
            send_file(pass_output_path, type: "application/vnd.apple.pkpass", disposition: "attachment")
          else
            head :not_modified
          end
        end

        private

        # Decrypt the URL payload, validate its shape, and check expiry.
        # Tampered, malformed, or expired payloads all 404 (not 500) so the
        # endpoint cannot be probed for crypto errors.
        def decrypt_payload
          @payload = Passkit::UrlEncrypt.decrypt(params[:payload])
          return head(:not_found) unless allowed_pass_class?(@payload[:pass_class])
          return head(:not_found) unless allowed_generator_class?(@payload[:generator_class])
          return head(:not_found) unless valid_until_in_future?(@payload[:valid_until]) # standard:disable Style/RedundantReturn
        rescue OpenSSL::Cipher::CipherError, JSON::ParserError
          head :not_found
        end

        def valid_until_in_future?(value)
          parsed = parse_time(value)
          !parsed.nil? && !parsed.past?
        end

        # Resolves the polymorphic generator referenced by the payload. Uses
        # `find_by` + explicit `head :not_found` rather than `find` so the 404
        # is self-contained and does not rely on Rails' show_exceptions
        # middleware (which behaves differently in API-only apps and tests).
        def set_generator
          @generator = nil

          return unless @payload[:generator_class].present? && @payload[:generator_id].present?

          generator_class = @payload[:generator_class].constantize
          @generator = generator_class.find_by(id: @payload[:generator_id])
          return head(:not_found) if @generator.nil? # standard:disable Style/RedundantReturn
        end

        # Parses both ISO 8601 (encrypted payload's valid_until) and RFC 2616
        # HTTP-date (If-Modified-Since header) into Time.zone instances. Returns
        # nil for nil / blank / unparseable input.
        def parse_time(value)
          return nil if value.nil? || value.to_s.empty?
          Time.zone.parse(value.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        # Optional defense-in-depth: when the host app configures
        # `Passkit.configuration.pass_classes`, the payload's pass_class must
        # appear in that list before constantize is called. Empty config means
        # "no allowlist", preserving backward compatibility.
        def allowed_pass_class?(name)
          allowlist = Array(Passkit.configuration&.pass_classes).map(&:to_s)
          return true if allowlist.empty?
          allowlist.include?(name.to_s)
        end

        def allowed_generator_class?(name)
          return true if name.nil?
          allowlist = Array(Passkit.configuration&.pass_generators).map(&:to_s)
          return true if allowlist.empty?
          allowlist.include?(name.to_s)
        end

        # `collection_name` becomes a `public_send` argument; restrict it to
        # AR association names declared on the generator class so it can never
        # be coerced into calling `destroy`, `delete_all`, etc.
        def validated_collection_name(generator, name)
          symbol = name.to_sym
          return symbol if generator.class.respond_to?(:reflect_on_association) &&
            generator.class.reflect_on_association(symbol)
          nil
        end
      end
    end
  end
end
