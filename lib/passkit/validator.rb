require "time"

module Passkit
  # Validates a `pass.json` hash against Apple's PassKit schema, raising
  # Passkit::ValidationError with a descriptive message on failure. Designed
  # to catch typos, bad enum values, and malformed sub-objects at generation
  # time rather than at install time.
  #
  # Unknown semantic keys are intentionally accepted — Apple adds them every
  # iOS cycle, and a strict allowlist would force a gem release each time.
  # Only keys with known shapes are type-checked.
  class Validator
    COLOR_REGEX = /\Argb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)\z/
    URL_REGEX = /\Ahttps?:\/\//

    PASS_TYPES = %i[storeCard coupon eventTicket generic boardingPass].freeze
    BARCODE_FORMATS = %w[
      PKBarcodeFormatQR PKBarcodeFormatPDF417 PKBarcodeFormatAztec PKBarcodeFormatCode128
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
    PREFERRED_STYLE_SCHEMES = %w[posterEventTicket].freeze
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
      def validate!(pass_hash)
        errors = validate(pass_hash)
        return if errors.empty?
        raise Passkit::ValidationError, errors.join("; ")
      end

      def validate(pass_hash)
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

        errors
      end

      private

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)
        hash[key] || hash[key.to_s]
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
        %i[sharingProhibited suppressStripShine voided useAutomaticColors].each do |key|
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
          %i[headerFields primaryFields secondaryFields auxiliaryFields backFields].each do |fkey|
            fields = fetch(block, fkey)
            next if fields.nil?
            unless fields.is_a?(Array)
              errors << "#{type}.#{fkey} must be an Array"
              next
            end
            fields.each_with_index do |field, i|
              validate_pass_field_content(field, "#{type}.#{fkey}[#{i}]", errors)
            end
          end
          if type == :boardingPass
            tt = fetch(block, :transitType)
            if tt && !TRANSIT_TYPES.include?(tt)
              errors << "boardingPass.transitType must be one of #{TRANSIT_TYPES.join(", ")} — got #{tt.inspect}"
            end
          end
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

      def validate_additional_info_fields(pass, errors)
        fields = fetch(pass, :additionalInfoFields)
        return if fields.nil?
        unless fields.is_a?(Array)
          errors << "additionalInfoFields must be an Array"
          return
        end
        fields.each_with_index { |f, i| validate_pass_field_content(f, "additionalInfoFields[#{i}]", errors) }
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
          start_str = fetch(entry, :startDate)
          end_str = fetch(entry, :endDate)
          if start_str.nil?
            errors << "#{label}.startDate is required"
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
      rescue ArgumentError
        errors << "#{label} is not valid ISO 8601 — got #{str.inspect}"
        nil
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
          flightCode flightNumber departureAirportCode departureAirportName
          departureAirportTerminal departureAirportGate destinationAirportCode
          destinationAirportName destinationAirportTerminal destinationAirportGate
          carNumber departurePlatform destinationPlatform departureStationName
          destinationStationName vehicleName vehicleNumber vehicleType
          ticketFareClass entranceDescription leagueName leagueAbbreviation
          sportName homeTeamName homeTeamLocation homeTeamAbbreviation
          awayTeamName awayTeamLocation awayTeamAbbreviation
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

        # Numeric-typed keys
        %i[duration boardingSequenceNumber].each do |key|
          val = fetch(sem, key)
          next if val.nil?
          unless val.is_a?(Numeric)
            errors << "#{label}.#{key} must be Numeric — got #{val.inspect}"
          end
        end

        # Array-of-string keys
        %i[
          performerNames artistIDs albumIDs playlistIDs loungePlaceIDs
          passengerCapabilities passengerAirlineSSRs passengerInformationSSRs
          passengerServiceSSRs passengerEligibleSecurityPrograms
          departureLocationSecurityPrograms destinationLocationSecurityPrograms
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
        if (entrance = fetch(sem, :venueEntrance))
          validate_location_object(entrance, "#{label}.venueEntrance", errors, require_lat_lon: false)
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
