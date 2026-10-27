module Passkit
  module Api
    module V1
      class LogsController < ActionController::API
        # Apple's log endpoint takes no authentication, so a single request
        # stores a bounded amount: the first MAX_ENTRIES strings, each cut to
        # MAX_LENGTH characters. Rate limiting is the host app's job.
        MAX_ENTRIES = 50
        MAX_LENGTH = 2_000

        def create
          messages = Array(params[:logs]).select { |m| m.is_a?(String) || m.is_a?(Numeric) }
          messages.first(MAX_ENTRIES).each do |message|
            Log.create!(content: message.to_s.truncate(MAX_LENGTH, omission: ""))
          end
          render json: {}, status: :ok
        end
      end
    end
  end
end
