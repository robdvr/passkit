module Passkit
  module Dashboard
    class PreviewsController < ApplicationController
      def index
      end

      def show
        builder = Passkit.configuration.available_passes[params[:class_name]]
        raise ActionController::RoutingError, "Unknown pass class #{params[:class_name].inspect}" unless builder

        path = Factory.create_pass(params[:class_name].constantize, builder.call)

        send_file path, type: "application/vnd.apple.pkpass", disposition: "attachment", filename: "pass.pkpass"
      end
    end
  end
end
