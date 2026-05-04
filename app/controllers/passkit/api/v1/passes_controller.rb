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

            collection = @generator.public_send(collection_name)

            if apple_wallet_client?
              files = collection.collect do |collection_item|
                Passkit::Factory.create_pass(@payload[:pass_class], collection_item)
              end
              file = Passkit::Generator.compress_passes_files(files)
              send_file(file, type: "application/vnd.apple.pkpasses", disposition: "attachment")
            else
              # `.pkpasses` bundles are only understood by iOS Wallet. Browsers
              # and Android third-party readers get a per-pass HTML index so
              # the user can install each pass individually.
              render plain: bundle_index_html(collection), content_type: "text/html"
            end
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

        # iOS Wallet identifies its UA as `PassKit/<ver>` (older iOS) or
        # `Wallet/<ver>` (newer iOS) when fetching a pass URL — and the
        # token is always at the very start of the UA. Anchoring with `\A`
        # avoids two classes of false positive that `\b…/` lets through:
        #   - "Google Wallet/2.0"   (space-W boundary still satisfies \b)
        #   - "My Wallet App/1.0"   (slash after App, but \bWallet\b matches)
        # If middleware ever prepends a token to Apple's UA the check will
        # fail and the client gets the HTML index — graceful degradation
        # is preferable to a `.pkpasses` bundle the client cannot open.
        def apple_wallet_client?
          request.user_agent.to_s.match?(%r{\A(PassKit|Wallet)/})
        end

        # Per-pass URLs reuse the same encrypted-payload contract as the
        # initial collection request, just with `collection_name` cleared
        # and the per-item record as the generator. Each click creates one
        # `Passkit::Pass` row, matching the single-pass code path.
        def bundle_index_html(collection)
          items = collection.to_a
          links = items.map { |item| bundle_index_link(item) }.join

          <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Your passes</title>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                     max-width: 32rem; margin: 2rem auto; padding: 0 1rem; color: #111; }
              h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
              p { color: #444; line-height: 1.4; }
              ul { list-style: none; padding: 0; margin: 1.5rem 0; }
              li { margin: 0.5rem 0; }
              a { display: block; padding: 1rem; background: #f3f4f6;
                  border-radius: 0.5rem; text-decoration: none; color: #111; }
              code { background: #eee; padding: 0 0.25rem; border-radius: 0.25rem; }
            </style>
            </head>
            <body>
            <h1>Your passes (#{items.length})</h1>
            <p>Apple's bundled <code>.pkpasses</code> format is only understood by
            iOS Wallet, so each pass is offered separately here. Tap a pass to add
            it to your wallet.</p>
            <ul>#{links}</ul>
            </body>
            </html>
          HTML
        end

        def bundle_index_link(item)
          klass_name = item.class.name
          # DX warning: the security-relevant allowlist check happens at
          # decrypt time on the next request. If we emit a link whose
          # generator_class isn't in the allowlist, the click silently 404s.
          # Surface that here so it's caught in dev rather than production.
          if !allowed_generator_class?(klass_name)
            Rails.logger.warn(
              "[Passkit] bundle_index_link: #{klass_name} is not in " \
              "Passkit.configuration.pass_generators — link will 404 when clicked."
            )
          end

          payload = Passkit::UrlEncrypt.encrypt(
            valid_until: Passkit::PayloadGenerator::VALIDITY.from_now,
            generator_class: klass_name,
            generator_id: item.id,
            pass_class: @payload[:pass_class],
            collection_name: nil
          )
          label = item.try(:name).presence || "Pass ##{item.id}"
          %(<li><a href="#{ERB::Util.h(passes_api_path(payload))}">#{ERB::Util.h(label)}</a></li>)
        end
      end
    end
  end
end
