module Passkit
  class BasePass
    def initialize(generator = nil)
      @generator = generator
    end

    def format_version
      # Apple's spec requires a JSON integer here. ENV strings get coerced.
      ENV["PASSKIT_FORMAT_VERSION"]&.to_i || 1
    end

    def apple_team_identifier
      ENV["PASSKIT_APPLE_TEAM_IDENTIFIER"] || raise(Error.new("Missing environment variable: PASSKIT_APPLE_TEAM_IDENTIFIER"))
    end

    def pass_type_identifier
      ENV["PASSKIT_PASS_TYPE_IDENTIFIER"] || raise(Error.new("Missing environment variable: PASSKIT_PASS_TYPE_IDENTIFIER"))
    end

    def language
      nil
    end

    def last_update
      @generator&.updated_at
    end

    def pass_path
      rails_folder = Rails.root.join("private/passkit/#{folder_name}")
      # if folder exists, otherwise is in the gem itself under lib/passkit/base_pass
      if File.directory?(rails_folder)
        rails_folder
      else
        File.join(File.dirname(__FILE__), folder_name)
      end
    end

    def pass_type
      :storeCard
      # :coupon
      # :eventTicket
      # :generic
      # :boardingPass
    end

    def web_service_url
      raise Error.new("Missing environment variable: PASSKIT_WEB_SERVICE_HOST") unless ENV["PASSKIT_WEB_SERVICE_HOST"]
      "#{ENV["PASSKIT_WEB_SERVICE_HOST"]}/passkit/api"
    end

    # The foreground color, used for the values of fields shown on the front of the pass.
    def foreground_color
      # black
      "rgb(0, 0, 0)"
    end

    # The background color, used for the background of the front and back of the pass.
    # If you provide a background image, any background color is ignored.
    def background_color
      # white
      "rgb(255, 255, 255)"
    end

    # The label color, used for the labels of fields shown on the front of the pass.
    def label_color
      # black
      "rgb(0, 0, 0)"
    end

    # The organization name is displayed on the lock screen when your pass is relevant and by apps such as Mail which
    # act as a conduit for passes. The value for the organizationName key in the pass specifies the organization name.
    # Choose a name that users recognize and associate with your organization or company.
    def organization_name
      "Passkit"
    end

    # The description lets VoiceOver make your pass accessible to blind and low-vision users. The value for the
    # description key in the pass specifies the description.
    # @see https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html
    def description
      "A basic description for a pass"
    end

    # An array of up to 10 latitudes and longitudes. iOS uses these locations to determine when to display the pass on the lock screen
    #
    # @see https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html
    def locations
      []
    end

    def voided
      false
    end

    # After base files are copied this is called to allow for adding custom images
    def add_other_files(path)
    end

    # Distance in meters from locations; if blank uses pass default.
    # The system uses the smaller of either this distance or the default distance.
    def max_distance
    end

    # URL to launch the associated app (nil by default)
    # Returns a String
    def app_launch_url
    end

    # A list of Apple App Store identifiers for apps associated
    # with the pass. The first one that is compatible with the
    # device is picked.
    # Returns an array of numbers
    def associated_store_identifiers
      []
    end

    # An array of barcodes, the first one that can
    # be displayed on the device is picked.
    # Returns an array of hashes representing Pass.Barcodes
    def barcodes
      []
    end

    # List of iBeacon identifiers to identify when the
    # pass should be displayed.
    # Returns an array of hashes representing Pass.Beacons
    def beacons
      []
    end

    # Information specific to a boarding pass
    # Returns a hash representing Pass.BoardingPass
    # https://developer.apple.com/documentation/walletpasses/pass/boardingpass
    # i.e {transitType: 'PKTransitTypeGeneric'}
    def boarding_pass
      {}
    end

    # Date and time the pass expires, must include
    # days, hours and minutes (seconds are optional)
    # Returns a String representing the date and time in W3C format ('%Y-%m-%dT%H:%M:%S%:z')
    # For example, 1980-05-07T10:30-05:00.
    def expiration_date
    end

    # A key to identify group multiple passes together
    # (e.g. a number of boarding passes for the same trip)
    # Returns a String
    def grouping_identifier
    end

    # Information specific to Value Added Service Protocol
    # transactions
    # Returns a hash representing Pass.NFC
    def nfc
    end

    # Date and time when the pass becomes relevant and should be
    # displayed, must include days, hours and minutes
    # (seconds are optional)
    # Returns a String representing the date and time in W3C format ('%Y-%m-%dT%H:%M:%S%:z')
    def relevant_date
    end

    # Machine readable metadata that the device can use
    # to suggest actions
    # Returns a hash representing SemanticTags
    def semantics
    end

    # Display the strip image without a shine effect
    # Returns a boolean
    def suppress_strip_shine
      true
    end

    # JSON dictionary to display custom information for
    # companion apps. Data isn't displayed to the user. e.g.
    # a machine readable version of the user's favourite coffee
    def user_info
    end

    def file_name
      @file_name ||= SecureRandom.uuid
    end

    # QRCode by default
    def barcode
      {messageEncoding: "iso-8859-1",
       format: "PKBarcodeFormatQR",
       message: "https://github.com/coorasse/passkit",
       altText: "https://github.com/coorasse/passkit"}
    end

    # Barcode example
    # def barcode
    #   { messageEncoding: 'iso-8859-1',
    #     format: 'PKBarcodeFormatCode128',
    #     message: '12345',
    #     altText: '12345' }
    # end

    def logo_text
      "Logo text"
    end

    def header_fields
      []
    end

    def primary_fields
      []
    end

    def secondary_fields
      []
    end

    def auxiliary_fields
      []
    end

    def back_fields
      []
    end

    def sharing_prohibited
      false
    end

    # iOS 18+ enhanced (poster-style) event ticket layout opt-in.
    # Returns an array of style scheme strings, e.g. `["posterEventTicket"]`.
    # When set, iOS 18+ Wallet renders the poster layout and ignores most of
    # the legacy header/primary/secondary field arrays. iOS ≤17 ignores this
    # key and renders the classic layout — keep field arrays populated for
    # backwards compatibility.
    #
    # NOTE: poster-style images (background / artwork / event logo) and the
    # canonical filenames are not pinned in Apple's public docs. The gem's
    # Generator copies every file in `pass_path` recursively, so supply
    # whichever filenames your target iOS version expects.
    # @see https://developer.apple.com/documentation/walletpasses/pass
    def preferred_style_schemes
      nil
    end

    # iOS 18+ additional info row(s) shown in the pass detail view.
    # Returns an array of PassFieldContent hashes (same shape as
    # `header_fields` etc.: `{key:, label:, value:, ...}`).
    def additional_info_fields
      []
    end

    # iOS 18+ branded text shown next to the event logo on the poster face.
    def event_logo_text
      nil
    end

    # iOS 18+ array of relevance windows (replaces singular `relevant_date`).
    # Each entry is `{startDate: ISO8601, endDate: ISO8601}`. Apple caps each
    # window at 24h. Both keys may be set; iOS 18+ prefers `relevant_dates`.
    def relevant_dates
      []
    end

    # iOS 18+ opt-in to automatic foreground/label color extraction from the
    # background image. Boolean (or nil to omit).
    def use_automatic_colors
      nil
    end

    # iOS 18+ footer background color (rgb(...) string).
    def footer_background_color
      nil
    end

    # iOS 18+ secondary list of App Store identifiers for related apps.
    def auxiliary_store_identifiers
      []
    end

    # Venue utility URL fields (iOS 18+). Each returns a string URL or nil.
    # Apple surfaces these as tappable rows in the enhanced ticket detail view.
    def bag_policy_url
      nil
    end

    def parking_information_url
      nil
    end

    def merchandise_url
      nil
    end

    def order_food_url
      nil
    end

    def transit_information_url
      nil
    end

    def directions_information_url
      nil
    end

    def transfer_url
      nil
    end

    def add_on_url
      nil
    end

    def accessibility_url
      nil
    end

    def purchase_parking_url
      nil
    end

    def sell_url
      nil
    end

    def contact_venue_email
      nil
    end

    def contact_venue_phone_number
      nil
    end

    def contact_venue_website
      nil
    end

    # Localized strings for `<lang>.lproj/pass.strings` files.
    # Returns a hash keyed by locale (string or symbol), e.g.
    #   { en: { "EVENT" => "Event", "DOORS" => "Doors" },
    #     es: { "EVENT" => "Evento", "DOORS" => "Puertas" } }
    # Field `value`s referencing these keys (e.g. `value: "EVENT"`) are
    # substituted by Wallet at render time per the device language.
    def localized_strings
      {}
    end

    private

    def folder_name
      self.class.name.demodulize.underscore
    end
  end
end
