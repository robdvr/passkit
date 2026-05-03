module Passkit
  module Api
    module V1
      # This Class Implements the Apple PassKit API
      # @see Apple: https://developer.apple.com/library/archive/documentation/PassKit/Reference/PassKit_WebService/WebService.html
      # @see Android: https://walletpasses.io/developer/
      class RegistrationsController < ActionController::API
        before_action :load_pass, only: %i[create destroy]
        before_action :load_device, only: %i[show]

        # @return If the serial number is already registered for this device, returns HTTP status 200.
        # @return If registration succeeds, returns HTTP status 201.
        # @return If the request is not authorized, returns HTTP status 401.
        # @return Otherwise, returns the appropriate standard HTTP status.
        def create
          if @pass.devices.find_by(identifier: params[:device_id])
            render json: {}, status: :ok
            return
          end

          register_device
          render json: {}, status: :created
        end

        # @return If there are matching passes, returns HTTP status 200
        #         with a JSON dictionary with the following keys and values:
        #         lastUpdated (string): The current modification tag.
        #         serialNumbers (array of strings): The serial numbers of the matching passes.
        # @return If there are no matching passes, returns HTTP status 204.
        # @return Otherwise, returns the appropriate standard HTTP status
        def show
          if @device.nil?
            render json: {}, status: :not_found
            return
          end

          passes = fetch_registered_passes
          if passes.none?
            render json: {}, status: :no_content
            return
          end

          render json: updatable_passes(passes)
        end

        # @return If disassociation succeeds, returns HTTP status 200.
        # @return If the request is not authorized, returns HTTP status 401.
        # @return Otherwise, returns the appropriate standard HTTP status.
        def destroy
          device = Passkit::Device.find_by(identifier: params[:device_id])
          @pass.registrations.where(device: device).delete_all if device
          render json: {}, status: :ok
        end

        private

        def load_pass
          authentication_token = request.headers["Authorization"]&.split(" ")&.last
          unless authentication_token.present?
            render json: {}, status: :unauthorized
            return
          end

          @pass = Pass.find_by(serial_number: params[:serial_number], authentication_token: authentication_token)
          unless @pass
            render json: {}, status: :unauthorized
          end
        end

        def load_device
          @device = Passkit::Device.find_by(identifier: params[:device_id])
        end

        def register_device
          device = Passkit::Device.find_or_create_by!(identifier: params[:device_id])
          token = push_token
          device.update!(push_token: token) if token.present? && device.push_token != token
          @pass.registrations.create!(device: device)
        end

        def fetch_registered_passes
          passes = @device.passes
          return passes unless params[:passesUpdatedSince]&.present?

          since = begin
            Date.parse(params[:passesUpdatedSince])
          rescue ArgumentError, TypeError
            return passes
          end
          passes.where("passkit_passes.updated_at >= ?", since)
        end

        def updatable_passes(passes)
          {lastUpdated: Time.zone.now, serialNumbers: passes.pluck(:serial_number)}
        end

        def push_token
          # Apple posts {"pushToken": "..."} as JSON; Rails parses application/json
          # bodies into params automatically. Fall back to raw-body parse for
          # callers that POST without the proper Content-Type.
          return params[:pushToken] if params.key?(:pushToken)

          raw = request.raw_post
          return nil if raw.blank?

          JSON.parse(raw)["pushToken"]
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
