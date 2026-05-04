require "zip"

module Passkit
  class Generator
    TMP_FOLDER = Rails.root.join("tmp/passkit").freeze

    def initialize(pass)
      @pass = pass
      @generator = pass.generator
    end

    def generate_and_sign
      check_necessary_files
      create_temporary_directory
      copy_pass_to_tmp_location
      @pass.instance.add_other_files(@temporary_path)
      Passkit::Localization.write_strings(@temporary_path, @pass.localized_strings)
      clean_ds_store_files
      I18n.with_locale(@pass.language) do
        generate_json_pass
      end
      generate_json_manifest
      sign_manifest
      compress_pass_file
    end

    def self.compress_passes_files(files)
      zip_path = TMP_FOLDER.join("#{SecureRandom.uuid}.pkpasses")
      File.open(zip_path, "wb") {} # ensure binary mode

      Zip::OutputStream.open(zip_path.to_s) do |z|
        files.each do |file|
          z.put_next_entry(File.basename(file))
          z.print File.binread(file)
        end
      end
      zip_path
    end

    private

    def check_necessary_files
      raise "icon.png is not present in #{@pass.pass_path}" unless File.exist?(File.join(@pass.pass_path, "icon.png"))
    end

    def create_temporary_directory
      FileUtils.mkdir_p(TMP_FOLDER) unless File.directory?(TMP_FOLDER)
      @temporary_path = TMP_FOLDER.join(@pass.file_name.to_s)

      FileUtils.rm_rf(@temporary_path) if File.directory?(@temporary_path)
    end

    def copy_pass_to_tmp_location
      FileUtils.cp_r(@pass.pass_path, @temporary_path)
    end

    def clean_ds_store_files
      Dir.glob(@temporary_path.join("**/.DS_Store")).each { |file| File.delete(file) }
    end

    def generate_json_pass
      pass = {
        formatVersion: @pass.format_version,
        teamIdentifier: @pass.apple_team_identifier,
        authenticationToken: @pass.authentication_token,
        backgroundColor: @pass.background_color,
        description: @pass.description,
        foregroundColor: @pass.foreground_color,
        labelColor: @pass.label_color,
        organizationName: @pass.organization_name,
        passTypeIdentifier: @pass.pass_type_identifier,
        serialNumber: @pass.serial_number,
        sharingProhibited: @pass.sharing_prohibited,
        suppressStripShine: @pass.suppress_strip_shine,
        voided: @pass.voided,
        webServiceURL: @pass.web_service_url
      }

      # Apple's spec marks `locations` and `logoText` as optional. Strict iOS
      # Wallet versions reject `null` for typed string fields and `[]` for
      # optional array fields — the install silently fails on iPhone with no
      # user-visible error. Pass Viewer on macOS is more permissive and
      # accepts both, so the bug only surfaces on real devices. Omit these
      # keys when the host pass returns nil/empty so the JSON matches Apple's
      # optional-field convention.
      pass[:locations] = @pass.locations if @pass.locations.is_a?(Array) && @pass.locations.any?
      pass[:logoText] = @pass.logo_text if @pass.logo_text.respond_to?(:to_s) && !@pass.logo_text.to_s.empty?

      pass[:maxDistance] = @pass.max_distance if @pass.max_distance

      # If the newer barcodes attribute has been used, then
      # include the list of barcodes, otherwise fall back to
      # the original barcode attribute
      barcodes = @pass.barcodes || []
      if barcodes.empty?
        pass[:barcode] = @pass.barcode
      else
        pass[:barcodes] = @pass.barcodes
      end
      pass[:appLaunchURL] = @pass.app_launch_url if @pass.app_launch_url
      pass[:associatedStoreIdentifiers] = @pass.associated_store_identifiers unless @pass.associated_store_identifiers.empty?
      pass[:auxiliaryStoreIdentifiers] = @pass.auxiliary_store_identifiers unless @pass.auxiliary_store_identifiers.empty?
      pass[:beacons] = @pass.beacons unless @pass.beacons.empty?
      pass[:expirationDate] = @pass.expiration_date if @pass.expiration_date
      pass[:groupingIdentifier] = @pass.grouping_identifier if @pass.grouping_identifier
      pass[:nfc] = @pass.nfc if @pass.nfc
      pass[:relevantDate] = @pass.relevant_date if @pass.relevant_date
      pass[:relevantDates] = @pass.relevant_dates unless @pass.relevant_dates.empty?
      pass[:semantics] = @pass.semantics if @pass.semantics
      pass[:userInfo] = @pass.user_info if @pass.user_info

      # iOS 18+ enhanced (poster-style) event ticket fields. All optional;
      # omitted unless the subclass overrides the corresponding method.
      pass[:preferredStyleSchemes] = @pass.preferred_style_schemes if @pass.preferred_style_schemes
      pass[:additionalInfoFields] = @pass.additional_info_fields unless @pass.additional_info_fields.empty?
      pass[:eventLogoText] = @pass.event_logo_text if @pass.event_logo_text
      pass[:useAutomaticColors] = @pass.use_automatic_colors unless @pass.use_automatic_colors.nil?
      pass[:footerBackgroundColor] = @pass.footer_background_color if @pass.footer_background_color

      # Venue utility URLs (iOS 18+).
      pass[:bagPolicyURL] = @pass.bag_policy_url if @pass.bag_policy_url
      pass[:parkingInformationURL] = @pass.parking_information_url if @pass.parking_information_url
      pass[:merchandiseURL] = @pass.merchandise_url if @pass.merchandise_url
      pass[:orderFoodURL] = @pass.order_food_url if @pass.order_food_url
      pass[:transitInformationURL] = @pass.transit_information_url if @pass.transit_information_url
      pass[:directionsInformationURL] = @pass.directions_information_url if @pass.directions_information_url
      pass[:transferURL] = @pass.transfer_url if @pass.transfer_url
      pass[:addOnURL] = @pass.add_on_url if @pass.add_on_url
      pass[:accessibilityURL] = @pass.accessibility_url if @pass.accessibility_url
      pass[:purchaseParkingURL] = @pass.purchase_parking_url if @pass.purchase_parking_url
      pass[:sellURL] = @pass.sell_url if @pass.sell_url
      pass[:contactVenueEmail] = @pass.contact_venue_email if @pass.contact_venue_email
      pass[:contactVenuePhoneNumber] = @pass.contact_venue_phone_number if @pass.contact_venue_phone_number
      pass[:contactVenueWebsite] = @pass.contact_venue_website if @pass.contact_venue_website

      pass[@pass.pass_type] = {
        headerFields: @pass.header_fields,
        primaryFields: @pass.primary_fields,
        secondaryFields: @pass.secondary_fields,
        auxiliaryFields: @pass.auxiliary_fields,
        backFields: @pass.back_fields
      }

      if @pass.pass_type == :boardingPass && @pass.boarding_pass
        pass[:boardingPass] = pass[:boardingPass].merge(@pass.boarding_pass)
      end

      Passkit::Validator.validate!(pass) if Passkit.configuration&.validate_pass_json

      File.write(@temporary_path.join("pass.json"), pass.to_json)
    end

    # rubocop:enable Metrics/AbcSize

    def generate_json_manifest
      # SHA-1 is mandated by Apple's PassKit spec for manifest entries; do not
      # change this digest without re-reading the spec.
      manifest = {}
      pass_files.each do |file|
        manifest[file.relative_path_from(@temporary_path).to_s] = Digest::SHA1.hexdigest(File.binread(file))
      end

      @manifest_url = @temporary_path.join("manifest.json")
      File.write(@manifest_url, manifest.to_json)
    end

    # standard:disable Metrics/AbcSize
    def sign_manifest
      certificate_path = Rails.root.join(ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"])
      intermediate_path = Rails.root.join(ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"])
      p12_certificate = OpenSSL::PKCS12.new(File.binread(certificate_path), ENV["PASSKIT_CERTIFICATE_KEY"])
      intermediate_certificate = OpenSSL::X509::Certificate.new(File.binread(intermediate_path))

      flag = OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY
      signed = OpenSSL::PKCS7.sign(p12_certificate.certificate,
        p12_certificate.key, File.binread(@manifest_url),
        [intermediate_certificate], flag)

      @signature_url = @temporary_path.join("signature")
      File.binwrite(@signature_url, signed.to_der)
    end
    # standard:enable Metrics/AbcSize

    def compress_pass_file
      zip_path = TMP_FOLDER.join("#{@pass.file_name}.pkpass")
      File.open(zip_path, "wb") {} # ensure binary mode

      Zip::OutputStream.open(zip_path.to_s) do |z|
        pass_files.each do |file|
          z.put_next_entry(file.relative_path_from(@temporary_path).to_s)
          z.print File.binread(file)
        end
      end
      zip_path
    end

    def pass_files
      Dir.glob(@temporary_path.join("**", "*")).map { |f| Pathname.new(f) }.select(&:file?)
    end
  end
end
