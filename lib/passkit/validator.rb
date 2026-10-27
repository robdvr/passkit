require "time"
require "uri"

module Passkit
  # Validates a `pass.json` hash against Apple's PassKit schema, raising
  # Passkit::ValidationError with a descriptive message on failure. Designed
  # to catch typos, bad enum values, and malformed sub-objects at generation
  # time rather than at install time.
  #
  # Unknown semantic keys are intentionally accepted — Apple adds them every
  # iOS cycle, and a strict allowlist would force a gem release each time.
  # Only keys with known shapes are type-checked.
  #
  # Shapes, enums and the poster requirements follow Apple's own pass model
  # and validators (github.com/apple/pass-builder, Sources/PassBuilder), which
  # Pass Designer and `buildpass validate` run.
  class Validator
    COLOR_REGEX = /\Argb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)\z/
    URL_REGEX = /\Ahttps?:\/\//

    PASS_TYPES = %i[storeCard coupon eventTicket generic boardingPass].freeze
    # Code39, Codabar, EAN13 and I2of5 (ITF) need iOS 27; list a QR or other
    # older format after them so earlier versions still show a barcode.
    BARCODE_FORMATS = %w[
      PKBarcodeFormatQR PKBarcodeFormatPDF417 PKBarcodeFormatAztec PKBarcodeFormatCode128
      PKBarcodeFormatCode39 PKBarcodeFormatCodabar PKBarcodeFormatEAN13 PKBarcodeFormatI2of5
    ].freeze
    DATE_STYLES = %w[
      PKDateStyleNone PKDateStyleShort PKDateStyleMedium PKDateStyleLong PKDateStyleFull
    ].freeze
    NUMBER_STYLES = %w[
      PKNumberStyleDecimal PKNumberStylePercent PKNumberStyleScientific PKNumberStyleSpellOut
    ].freeze
    TEXT_ALIGNMENTS = %w[
      PKTextAlignmentLeft PKTextAlignmentCenter PKTextAlignmentRight PKTextAlignmentNatural
    ].freeze
    DATA_DETECTOR_TYPES = %w[
      PKDataDetectorTypePhoneNumber PKDataDetectorTypeLink
      PKDataDetectorTypeAddress PKDataDetectorTypeCalendarEvent
    ].freeze
    # Apple pairs each semantic scheme with its fallback:
    # ["posterEventTicket", "eventTicket"], ["semanticBoardingPass", "boardingPass"].
    PREFERRED_STYLE_SCHEMES = %w[posterEventTicket eventTicket semanticBoardingPass boardingPass].freeze
    # iOS 27 featured action types, from Apple's "Add Featured Actions" table.
    FEATURED_ACTION_TYPES = %w[
      viewSchedule watchTrailer listenToMusic call place addToBalance order shop
      membershipBenefits bookAppointment bookCar bookFlight bookStay viewOffersRewards
    ].freeze
    MAX_FEATURED_ACTIONS = 2
    MAX_LOCATIONS = 10
    MAX_BEACONS = 10
    FIELD_LIST_KEYS = %i[
      headerFields primaryFields secondaryFields auxiliaryFields backFields additionalInfoFields footerFields
    ].freeze
    EVENT_TYPES = %w[
      PKEventTypeGeneric PKEventTypeLivePerformance PKEventTypeMovie PKEventTypeSports
      PKEventTypeConference PKEventTypeConvention PKEventTypeWorkshop PKEventTypeSocialGathering
    ].freeze
    TRANSIT_TYPES = %w[
      PKTransitTypeAir PKTransitTypeBoat PKTransitTypeBus PKTransitTypeGeneric PKTransitTypeTrain
    ].freeze

    REQUIRED_TOP_LEVEL = %i[
      formatVersion teamIdentifier passTypeIdentifier serialNumber
      organizationName description
    ].freeze

    # appLaunchURL intentionally excluded — Apple allows custom URL schemes
    # (e.g. `myapp://launch`) for deep linking into companion apps.
    URL_KEYS = %i[
      webServiceURL bagPolicyURL parkingInformationURL merchandiseURL
      orderFoodURL transitInformationURL directionsInformationURL transferURL addOnURL
      accessibilityURL purchaseParkingURL sellURL contactVenueWebsite
    ].freeze

    COLOR_KEYS = %i[backgroundColor foregroundColor labelColor footerBackgroundColor].freeze

    class << self
      def validate!(pass_hash, files: nil)
        errors = validate(pass_hash, files: files)
        return if errors.empty?
        raise Passkit::ValidationError, errors.join("; ")
      end

      # `files` is the list of file names in the pass folder (relative paths).
      # When given, the required images are checked too.
      def validate(pass_hash, files: nil)
        errors = []
        return ["pass must be a Hash"] unless pass_hash.is_a?(Hash)

        validate_required_top_level(pass_hash, errors)
        validate_format_version(pass_hash, errors)
        validate_colors(pass_hash, errors)
        validate_urls(pass_hash, errors)
        validate_booleans(pass_hash, errors)
        validate_iso8601_dates(pass_hash, errors)
        validate_pass_type_block(pass_hash, errors)
        validate_locations(pass_hash, errors)
        validate_beacons(pass_hash, errors)
        validate_barcode_singular(pass_hash, errors)
        validate_barcodes(pass_hash, errors)
        validate_associated_store_identifiers(pass_hash, errors)
        validate_auxiliary_store_identifiers(pass_hash, errors)
        validate_nfc(pass_hash, errors)
        validate_preferred_style_schemes(pass_hash, errors)
        validate_additional_info_fields(pass_hash, errors)
        validate_relevant_dates(pass_hash, errors)
        validate_semantics(pass_hash[:semantics] || pass_hash["semantics"], errors)
        validate_featured_actions(pass_hash, errors)
        validate_poster_generic(pass_hash, errors)
        validate_upcoming_pass_information(pass_hash, errors)
        validate_max_distance(pass_hash, errors)
        validate_poster_event_ticket(pass_hash, files, errors)
        validate_files(files, errors) if files

        errors
      end

      private

      # `||` would mask explicit `false` (or `0`) values — `{voided: false}`
      # would degrade to `nil` and skip the boolean type-check entirely. Use
      # `key?` semantics so the symbol form takes precedence whenever it's
      # explicitly present, regardless of value truthiness.
      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)
        return hash[key] if hash.key?(key)
        hash[key.to_s]
      end

      def validate_required_top_level(pass, errors)
        REQUIRED_TOP_LEVEL.each do |key|
          val = fetch(pass, key)
          errors << "#{key} is required" if val.nil? || (val.is_a?(String) && val.empty?)
        end
      end

      def validate_format_version(pass, errors)
        v = fetch(pass, :formatVersion)
        return if v.nil?
        errors << "formatVersion must be Integer" unless v.is_a?(Integer)
      end

      def validate_colors(pass, errors)
        COLOR_KEYS.each do |key|
          val = fetch(pass, key)
          next if val.nil?
          unless val.is_a?(String) && val.match?(COLOR_REGEX)
            errors << "#{key} must match rgb(r, g, b) — got #{val.inspect}"
          end
        end
      end

      def validate_urls(pass, errors)
        URL_KEYS.each do |key|
          val = fetch(pass, key)
          next if val.nil?
          unless val.is_a?(String) && val.match?(URL_REGEX)
            errors << "#{key} must be an http(s) URL — got #{val.inspect}"
          end
        end
        # webServiceURL specifically requires https
        ws = fetch(pass, :webServiceURL)
        if ws && !ws.start_with?("https://")
          errors << "webServiceURL must start with https://"
        end
      end

      def validate_booleans(pass, errors)
        %i[sharingProhibited suppressStripShine voided useAutomaticColors suppressHeaderDarkening].each do |key|
          val = fetch(pass, key)
          next if val.nil?
          unless val == true || val == false
            errors << "#{key} must be boolean — got #{val.inspect}"
          end
        end
      end

      def validate_iso8601_dates(pass, errors)
        %i[expirationDate relevantDate].each do |key|
          val = fetch(pass, key)
          next if val.nil?
          validate_iso8601(val, key, errors)
        end
      end

      def validate_iso8601(value, label, errors)
        unless value.is_a?(String)
          errors << "#{label} must be an ISO 8601 string — got #{value.inspect}"
          return
        end
        Time.iso8601(value)
      rescue ArgumentError
        errors << "#{label} is not valid ISO 8601 — got #{value.inspect}"
      end

      def validate_pass_type_block(pass, errors)
        # Find which (if any) pass-type key is present.
        present = PASS_TYPES.select { |t| fetch(pass, t) }
        if present.empty?
          errors << "pass must include one of #{PASS_TYPES.join(", ")} field block"
          return
        end
        if present.size > 1
          errors << "pass includes multiple pass-type blocks: #{present.join(", ")}"
        end
        present.each do |type|
          block = fetch(pass, type)
          unless block.is_a?(Hash)
            errors << "#{type} block must be a Hash"
            next
          end
          validate_field_lists(block, type, errors)
          if type == :boardingPass
            tt = fetch(block, :transitType)
            if tt && !TRANSIT_TYPES.include?(tt)
              errors << "boardingPass.transitType must be one of #{TRANSIT_TYPES.join(", ")} — got #{tt.inspect}"
            end
          end
        end
      end

      # Validates every field list of a style block (a PassFields object) and
      # that no two of its fields share a key, which Wallet refuses.
      def validate_field_lists(block, label, errors)
        keys = []
        FIELD_LIST_KEYS.each do |fkey|
          fields = fetch(block, fkey)
          next if fields.nil?
          unless fields.is_a?(Array)
            errors << "#{label}.#{fkey} must be an Array"
            next
          end
          fields.each_with_index do |field, i|
            validate_pass_field_content(field, "#{label}.#{fkey}[#{i}]", errors)
            keys << fetch(field, :key) if field.is_a?(Hash) && fetch(field, :key)
          end
        end
        keys.tally.each do |key, count|
          errors << "#{label} has duplicate field key #{key.inspect}" if count > 1
        end
      end

      def validate_pass_field_content(field, label, errors)
        unless field.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        %i[key value].each do |req|
          if fetch(field, req).nil?
            errors << "#{label}.#{req} is required"
          end
        end
        validate_enum(fetch(field, :dateStyle), DATE_STYLES, "#{label}.dateStyle", errors)
        validate_enum(fetch(field, :timeStyle), DATE_STYLES, "#{label}.timeStyle", errors)
        validate_enum(fetch(field, :numberStyle), NUMBER_STYLES, "#{label}.numberStyle", errors)
        validate_enum(fetch(field, :textAlignment), TEXT_ALIGNMENTS, "#{label}.textAlignment", errors)
        if fetch(field, :dateStyle) || fetch(field, :timeStyle)
          value = fetch(field, :value)
          unless value.is_a?(String) && iso8601?(value)
            errors << "#{label}.value must be ISO 8601 when dateStyle or timeStyle is set — got #{value.inspect}"
          end
        end
        %i[ignoresTimeZone isRelative].each do |flag|
          val = fetch(field, flag)
          next if val.nil? || val == true || val == false
          errors << "#{label}.#{flag} must be boolean — got #{val.inspect}"
        end
        change_message = fetch(field, :changeMessage)
        if change_message && !(change_message.is_a?(String) && change_message.include?("%@"))
          errors << "#{label}.changeMessage must contain %@ (the new value) — got #{change_message.inspect}"
        end
        currency = fetch(field, :currencyCode)
        if currency && !(currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/))
          errors << "#{label}.currencyCode must be a 3-letter ISO 4217 code — got #{currency.inspect}"
        end
        ddt = fetch(field, :dataDetectorTypes)
        if ddt
          if ddt.is_a?(Array)
            ddt.each { |t| validate_enum(t, DATA_DETECTOR_TYPES, "#{label}.dataDetectorTypes", errors) }
          else
            errors << "#{label}.dataDetectorTypes must be an Array"
          end
        end
        # Per-field semantics may appear; validate the same way as top-level.
        sem = fetch(field, :semantics)
        validate_semantics(sem, errors, label: "#{label}.semantics") if sem
      end

      def validate_enum(value, allowed, label, errors)
        return if value.nil?
        return if allowed.include?(value)
        errors << "#{label} must be one of #{allowed.join(", ")} — got #{value.inspect}"
      end

      def validate_locations(pass, errors)
        locs = fetch(pass, :locations)
        return if locs.nil?
        unless locs.is_a?(Array)
          errors << "locations must be an Array"
          return
        end
        errors << "locations holds at most #{MAX_LOCATIONS} entries — got #{locs.size}" if locs.size > MAX_LOCATIONS
        locs.each_with_index do |loc, i|
          validate_location_object(loc, "locations[#{i}]", errors, require_lat_lon: true)
        end
      end

      def validate_location_object(loc, label, errors, require_lat_lon: true)
        unless loc.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        %i[latitude longitude].each do |k|
          val = fetch(loc, k)
          if val.nil?
            errors << "#{label}.#{k} is required" if require_lat_lon
          elsif !val.is_a?(Numeric)
            errors << "#{label}.#{k} must be Numeric — got #{val.inspect}"
          end
        end
      end

      def validate_beacons(pass, errors)
        beacons = fetch(pass, :beacons)
        return if beacons.nil?
        unless beacons.is_a?(Array)
          errors << "beacons must be an Array"
          return
        end
        errors << "beacons holds at most #{MAX_BEACONS} entries — got #{beacons.size}" if beacons.size > MAX_BEACONS
        beacons.each_with_index do |b, i|
          unless b.is_a?(Hash)
            errors << "beacons[#{i}] must be a Hash"
            next
          end
          uuid = fetch(b, :proximityUUID)
          if uuid.nil? || !uuid.is_a?(String) || uuid.empty?
            errors << "beacons[#{i}].proximityUUID is required"
          end
        end
      end

      def validate_barcode_singular(pass, errors)
        bc = fetch(pass, :barcode)
        return if bc.nil?
        validate_barcode_object(bc, "barcode", errors)
      end

      def validate_barcodes(pass, errors)
        bcs = fetch(pass, :barcodes)
        return if bcs.nil?
        unless bcs.is_a?(Array)
          errors << "barcodes must be an Array"
          return
        end
        bcs.each_with_index { |b, i| validate_barcode_object(b, "barcodes[#{i}]", errors) }
      end

      def validate_barcode_object(bc, label, errors)
        unless bc.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        fmt = fetch(bc, :format)
        if fmt.nil?
          errors << "#{label}.format is required"
        elsif !BARCODE_FORMATS.include?(fmt)
          errors << "#{label}.format must be one of #{BARCODE_FORMATS.join(", ")} — got #{fmt.inspect}"
        end
        %i[message messageEncoding].each do |req|
          val = fetch(bc, req)
          if val.nil? || (val.is_a?(String) && val.empty?)
            errors << "#{label}.#{req} is required"
          end
        end
      end

      def validate_associated_store_identifiers(pass, errors)
        validate_integer_array(fetch(pass, :associatedStoreIdentifiers), "associatedStoreIdentifiers", errors)
      end

      def validate_auxiliary_store_identifiers(pass, errors)
        validate_integer_array(fetch(pass, :auxiliaryStoreIdentifiers), "auxiliaryStoreIdentifiers", errors)
      end

      def validate_integer_array(arr, label, errors)
        return if arr.nil?
        unless arr.is_a?(Array)
          errors << "#{label} must be an Array"
          return
        end
        arr.each_with_index do |v, i|
          unless v.is_a?(Integer)
            errors << "#{label}[#{i}] must be Integer — got #{v.inspect}"
          end
        end
      end

      def validate_nfc(pass, errors)
        nfc = fetch(pass, :nfc)
        return if nfc.nil?
        unless nfc.is_a?(Hash)
          errors << "nfc must be a Hash"
          return
        end
        %i[message encryptionPublicKey].each do |req|
          val = fetch(nfc, req)
          if val.nil? || (val.is_a?(String) && val.empty?)
            errors << "nfc.#{req} is required"
          end
        end
        ra = fetch(nfc, :requiresAuthentication)
        if !ra.nil? && ra != true && ra != false
          errors << "nfc.requiresAuthentication must be boolean — got #{ra.inspect}"
        end
      end

      def validate_preferred_style_schemes(pass, errors)
        schemes = fetch(pass, :preferredStyleSchemes)
        return if schemes.nil?
        unless schemes.is_a?(Array)
          errors << "preferredStyleSchemes must be an Array"
          return
        end
        schemes.each do |s|
          unless PREFERRED_STYLE_SCHEMES.include?(s)
            errors << "preferredStyleSchemes contains unknown value #{s.inspect} (allowed: #{PREFERRED_STYLE_SCHEMES.join(", ")})"
          end
        end
      end

      # Apple defines additionalInfoFields in PassFields, beside backFields.
      # At the top level of pass.json Wallet ignores it.
      def validate_additional_info_fields(pass, errors)
        return if fetch(pass, :additionalInfoFields).nil?
        errors << "additionalInfoFields belongs inside the pass style block (e.g. eventTicket), not at the top level"
      end

      def validate_relevant_dates(pass, errors)
        dates = fetch(pass, :relevantDates)
        return if dates.nil?
        unless dates.is_a?(Array)
          errors << "relevantDates must be an Array"
          return
        end
        dates.each_with_index do |entry, i|
          label = "relevantDates[#{i}]"
          unless entry.is_a?(Hash)
            errors << "#{label} must be a Hash"
            next
          end
          date_str = fetch(entry, :date)
          start_str = fetch(entry, :startDate)
          end_str = fetch(entry, :endDate)
          parse_iso(date_str, "#{label}.date", errors) unless date_str.nil?
          if start_str.nil?
            errors << "#{label} needs date or startDate" if date_str.nil?
            next
          end
          start_t = parse_iso(start_str, "#{label}.startDate", errors)
          if end_str.nil?
            # Single instant is valid (same as relevantDate behavior).
            next
          end
          end_t = parse_iso(end_str, "#{label}.endDate", errors)
          next unless start_t && end_t
          if end_t < start_t
            errors << "#{label}.endDate must be >= startDate"
          elsif (end_t - start_t) > 86_400
            errors << "#{label} window exceeds Apple's 24h cap"
          end
        end
      end

      def parse_iso(str, label, errors)
        Time.iso8601(str)
      rescue ArgumentError, TypeError
        errors << "#{label} is not valid ISO 8601 — got #{str.inspect}"
        nil
      end

      def iso8601?(str)
        Time.iso8601(str)
        true
      rescue ArgumentError, TypeError
        false
      end

      def validate_featured_actions(pass, errors)
        actions = fetch(pass, :featuredActions)
        return if actions.nil?
        unless actions.is_a?(Array)
          errors << "featuredActions must be an Array"
          return
        end
        if actions.size > MAX_FEATURED_ACTIONS
          errors << "featuredActions holds at most #{MAX_FEATURED_ACTIONS} actions — got #{actions.size}"
        end
        identifiers = []
        actions.each_with_index do |action, i|
          label = "featuredActions[#{i}]"
          unless action.is_a?(Hash)
            errors << "#{label} must be a Hash"
            next
          end
          identifier = fetch(action, :identifier)
          if identifier.is_a?(String) && !identifier.empty?
            identifiers << identifier
          else
            errors << "#{label}.identifier is required"
          end
          type = fetch(action, :type)
          if FEATURED_ACTION_TYPES.include?(type)
            validate_featured_action_target(action, type, label, errors)
          else
            errors << "#{label}.type must be one of #{FEATURED_ACTION_TYPES.join(", ")} — got #{type.inspect}"
          end
        end
        errors << "featuredActions identifiers must be unique" if identifiers.uniq.size != identifiers.size
      end

      # What Wallet's own validator requires of each type (checked against
      # PassKit on iOS 27 / macOS 27). An action missing its field still adds
      # from a file, but a web service update of the pass logs "Received
      # invalid pass data", which Apple says will become an error:
      # - place: `placeIdentifier`, an Apple Maps place ID. A Maps URL is not
      #   enough.
      # - call: a `tel:` url.
      # - every other type: an http(s) url.
      def validate_featured_action_target(action, type, label, errors)
        url = fetch(action, :url)
        case type
        when "place"
          place_id = fetch(action, :placeIdentifier)
          unless place_id.is_a?(String) && !place_id.strip.empty?
            errors << "#{label}.placeIdentifier (an Apple Maps place ID) is required for type place"
          end
          if url && !absolute_url?(url)
            errors << "#{label}.url must be an absolute URL — got #{url.inspect}"
          end
        when "call"
          unless url_with_scheme?(url, %w[tel])
            errors << "#{label}.url must be a tel: URL for type call — got #{url.inspect}"
          end
        else
          unless url_with_scheme?(url, %w[http https])
            errors << "#{label}.url must be an http(s) URL for type #{type} — got #{url.inspect}"
          end
        end
      end

      def url_with_scheme?(value, schemes)
        absolute_url?(value) && schemes.include?(URI.parse(value).scheme.downcase)
      end

      def absolute_url?(value)
        return false unless value.is_a?(String) && !value.match?(/\s/)
        uri = URI.parse(value)
        uri.scheme.present? && (uri.host.present? || uri.opaque.present?)
      rescue URI::InvalidURIError
        false
      end

      # iOS 27 Poster Generic: a PassFields object Wallet prefers over the
      # legacy style block, which still has to be present for iOS 26.
      def validate_poster_generic(pass, errors)
        block = fetch(pass, :posterGeneric)
        return if block.nil?
        unless block.is_a?(Hash)
          errors << "posterGeneric block must be a Hash"
          return
        end
        validate_field_lists(block, :posterGeneric, errors)
      end

      def validate_upcoming_pass_information(pass, errors)
        entries = fetch(pass, :upcomingPassInformation)
        return if entries.nil?
        unless entries.is_a?(Array)
          errors << "upcomingPassInformation must be an Array"
          return
        end
        entries.each_with_index do |entry, i|
          label = "upcomingPassInformation[#{i}]"
          unless entry.is_a?(Hash)
            errors << "#{label} must be a Hash"
            next
          end
          identifier = fetch(entry, :identifier)
          errors << "#{label}.identifier is required" unless identifier.is_a?(String) && !identifier.empty?
          active = fetch(entry, :isActive)
          errors << "#{label}.isActive must be boolean — got #{active.inspect}" unless active.nil? || active == true || active == false
          sem = fetch(entry, :semantics)
          validate_semantics(sem, errors, label: "#{label}.semantics") if sem
        end
      end

      def validate_max_distance(pass, errors)
        distance = fetch(pass, :maxDistance)
        return if distance.nil?
        return if distance.is_a?(Numeric) && distance >= 0
        errors << "maxDistance must be a non-negative number of meters — got #{distance.inspect}"
      end

      # Apple's EventTicketValidator: an eventTicket that asks for the poster
      # scheme must carry NFC (poster tickets are NFC-entry), the event and
      # venue names, and an artwork or background image. Wallet falls back to
      # the plain event ticket otherwise, silently, so fail at build time.
      def validate_poster_event_ticket(pass, files, errors)
        schemes = fetch(pass, :preferredStyleSchemes)
        return unless schemes.is_a?(Array) && schemes.include?("posterEventTicket") && fetch(pass, :eventTicket)

        nfc = fetch(pass, :nfc)
        if nfc.nil?
          errors << "posterEventTicket needs nfc (poster event tickets are NFC entry)"
        elsif nfc.is_a?(Hash) && fetch(nfc, :requiresAuthentication).nil?
          errors << "posterEventTicket needs nfc.requiresAuthentication"
        end

        sem = fetch(pass, :semantics) || {}
        required = %i[eventName venueName]
        case fetch(sem, :eventType)
        when "PKEventTypeSports" then required += %i[awayTeamAbbreviation homeTeamAbbreviation]
        when "PKEventTypeLivePerformance" then required += %i[performerNames]
        end
        required.each do |key|
          val = fetch(sem, key)
          errors << "posterEventTicket needs semantics.#{key}" if val.nil? || (val.respond_to?(:empty?) && val.empty?)
        end

        if files&.none? { |f| f.match?(%r{\A(artwork|background)(@[23]x)?\.png\z}) }
          errors << "posterEventTicket needs an artwork or background image"
        end
      end

      def validate_files(files, errors)
        errors << "icon.png is required" unless files.include?("icon.png")
      end

      # Known semantic sub-object shapes get type-checked. Unknown keys are
      # passed through silently — Apple adds new ones every iOS cycle.
      def validate_semantics(sem, errors, label: "semantics")
        return if sem.nil?
        unless sem.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end

        validate_enum(fetch(sem, :eventType), EVENT_TYPES, "#{label}.eventType", errors)

        # ISO 8601 date-typed keys
        %i[
          eventStartDate eventEndDate originalDepartureDate currentDepartureDate
          originalBoardingDate currentBoardingDate originalArrivalDate currentArrivalDate
          venueOpenDate venueCloseDate venueDoorsOpenDate venueGatesOpenDate
          venueBoxOfficeOpenDate venueFanZoneOpenDate venueParkingLotsOpenDate
        ].each do |key|
          val = fetch(sem, key)
          validate_iso8601(val, "#{label}.#{key}", errors) if val
        end

        # String-typed keys (light type check)
        %i[
          eventName venueName venuePhoneNumber venueRoom venueRegionName
          attendeeName admissionLevel admissionLevelAbbreviation
          additionalTicketAttributes genre transitProvider transitStatus
          transitStatusReason confirmationNumber boardingGroup boardingZone
          membershipProgramName membershipProgramNumber membershipProgramStatus
          priorityStatus securityScreening departureLocationDescription
          destinationLocationDescription departureCityName destinationCityName
          departureLocationTimeZone destinationLocationTimeZone airlineCode
          flightCode departureAirportCode departureAirportName
          departureAirportTerminal departureAirportGate destinationAirportCode
          destinationAirportName destinationAirportTerminal destinationAirportGate
          carNumber departurePlatform destinationPlatform departureStationName
          destinationStationName vehicleName vehicleNumber vehicleType
          ticketFareClass entranceDescription leagueName leagueAbbreviation
          sportName homeTeamName homeTeamLocation homeTeamAbbreviation
          awayTeamName awayTeamLocation awayTeamAbbreviation
          venueEntrance venueEntranceDoor venueEntranceGate venueEntrancePortal
          departureTerminal departureGate destinationTerminal destinationGate
          departureAirportTimeZone destinationAirportTimeZone airlineLoungePlaceID
          boardingSequenceNumber internationalDocumentsVerifiedDeclarationName
        ].each do |key|
          val = fetch(sem, key)
          next if val.nil?
          unless val.is_a?(String)
            errors << "#{label}.#{key} must be String — got #{val.inspect}"
          end
        end

        # Boolean-typed keys
        %i[silenceRequested tailgatingAllowed internationalDocumentsAreVerified].each do |key|
          val = fetch(sem, key)
          next if val.nil?
          unless val == true || val == false
            errors << "#{label}.#{key} must be boolean — got #{val.inspect}"
          end
        end

        # Integer-typed keys (Apple's model: `duration` seconds, `flightNumber`)
        %i[duration flightNumber].each do |key|
          val = fetch(sem, key)
          next if val.nil?
          unless val.is_a?(Integer)
            errors << "#{label}.#{key} must be Integer — got #{val.inspect}"
          end
        end

        # Array-of-string keys
        %i[
          performerNames artistIDs albumIDs playlistIDs loungePlaceIDs
          passengerCapabilities passengerAirlineSSRs passengerInformationSSRs
          passengerServiceSSRs passengerEligibleSecurityPrograms
          departureLocationSecurityPrograms destinationLocationSecurityPrograms
          departureAirportSecurityPrograms destinationAirportSecurityPrograms
        ].each do |key|
          val = fetch(sem, key)
          next if val.nil?
          unless val.is_a?(Array) && val.all? { |s| s.is_a?(String) }
            errors << "#{label}.#{key} must be Array of String — got #{val.inspect}"
          end
        end

        # Sub-objects
        if (loc = fetch(sem, :venueLocation))
          validate_location_object(loc, "#{label}.venueLocation", errors, require_lat_lon: true)
        end
        if (loc = fetch(sem, :departureLocation))
          validate_location_object(loc, "#{label}.departureLocation", errors, require_lat_lon: true)
        end
        if (loc = fetch(sem, :destinationLocation))
          validate_location_object(loc, "#{label}.destinationLocation", errors, require_lat_lon: true)
        end
        if (price = fetch(sem, :totalPrice))
          validate_currency_amount(price, "#{label}.totalPrice", errors)
        end
        if (balance = fetch(sem, :balance))
          validate_currency_amount(balance, "#{label}.balance", errors)
        end
        if (passenger = fetch(sem, :passengerName))
          validate_person_name(passenger, "#{label}.passengerName", errors)
        end
        if (info = fetch(sem, :eventStartDateInfo))
          validate_event_date_info(info, "#{label}.eventStartDateInfo", errors)
        end
        if (seats = fetch(sem, :seats))
          if seats.is_a?(Array)
            seats.each_with_index { |s, i| validate_seat(s, "#{label}.seats[#{i}]", errors) }
          else
            errors << "#{label}.seats must be an Array"
          end
        end
        if (wifi = fetch(sem, :wifiAccess))
          if wifi.is_a?(Array)
            wifi.each_with_index { |w, i| validate_wifi(w, "#{label}.wifiAccess[#{i}]", errors) }
          else
            errors << "#{label}.wifiAccess must be an Array"
          end
        end
      end

      def validate_currency_amount(obj, label, errors)
        unless obj.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        amount = fetch(obj, :amount)
        unless amount.is_a?(String) && !amount.empty?
          errors << "#{label}.amount must be a non-empty String"
        end
        code = fetch(obj, :currencyCode)
        unless code.is_a?(String) && code.length == 3
          errors << "#{label}.currencyCode must be a 3-letter ISO 4217 code — got #{code.inspect}"
        end
      end

      def validate_person_name(obj, label, errors)
        unless obj.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        %i[givenName familyName middleName namePrefix nameSuffix nickname phoneticRepresentation].each do |k|
          val = fetch(obj, k)
          next if val.nil?
          unless val.is_a?(String)
            errors << "#{label}.#{k} must be String — got #{val.inspect}"
          end
        end
      end

      def validate_event_date_info(obj, label, errors)
        unless obj.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        date = fetch(obj, :date)
        validate_iso8601(date, "#{label}.date", errors) if date
        tz = fetch(obj, :timeZone)
        if tz && !tz.is_a?(String)
          errors << "#{label}.timeZone must be String — got #{tz.inspect}"
        end
        %i[ignoreTimeComponents unannounced undetermined].each do |k|
          val = fetch(obj, k)
          next if val.nil?
          unless val == true || val == false
            errors << "#{label}.#{k} must be boolean — got #{val.inspect}"
          end
        end
      end

      def validate_seat(seat, label, errors)
        unless seat.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        %i[seatIdentifier seatNumber seatRow seatSection seatType seatDescription seatLevel seatAisle].each do |k|
          val = fetch(seat, k)
          next if val.nil?
          unless val.is_a?(String)
            errors << "#{label}.#{k} must be String — got #{val.inspect}"
          end
        end
        color = fetch(seat, :seatSectionColor)
        if color && !(color.is_a?(String) && color.match?(COLOR_REGEX))
          errors << "#{label}.seatSectionColor must match rgb(r, g, b) — got #{color.inspect}"
        end
      end

      def validate_wifi(wifi, label, errors)
        unless wifi.is_a?(Hash)
          errors << "#{label} must be a Hash"
          return
        end
        %i[ssid password].each do |req|
          val = fetch(wifi, req)
          if val.nil? || (val.is_a?(String) && val.empty?)
            errors << "#{label}.#{req} is required"
          end
        end
      end
    end
  end
end
