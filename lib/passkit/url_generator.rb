module Passkit
  class UrlGenerator
    include Passkit::Engine.routes.url_helpers

    def initialize(pass_class, generator = nil, collection_name = nil)
      @url = passes_api_url(host: ENV["PASSKIT_WEB_SERVICE_HOST"],
        payload: PayloadGenerator.encrypted(pass_class, generator, collection_name))
    end

    # Same `.pkpass` download URL is served to both platforms. iOS opens it in
    # Apple Wallet natively; Android opens it with whichever installed app
    # handles the `application/vnd.apple.pkpass` MIME type (e.g. Google Wallet
    # or a third-party reader). No 3rd-party redirect is involved.
    def ios
      @url
    end

    alias_method :android, :ios
  end
end
