# frozen_string_literal: true

require "rails_helper"

class TestValidator < ActiveSupport::TestCase
  # Minimal valid pass.json fragment used as a baseline. Each test starts
  # from this and mutates one field, so every test is self-contained and
  # order-independent.
  def base_pass
    {
      formatVersion: 1,
      teamIdentifier: "ABC1234567",
      passTypeIdentifier: "pass.com.example.test",
      serialNumber: "abc-123",
      organizationName: "Acme",
      description: "Test pass",
      foregroundColor: "rgb(0, 0, 0)",
      backgroundColor: "rgb(255, 255, 255)",
      labelColor: "rgb(0, 0, 0)",
      webServiceURL: "https://example.com/passkit/api",
      sharingProhibited: false,
      suppressStripShine: true,
      voided: false,
      storeCard: {
        headerFields: [],
        primaryFields: [],
        secondaryFields: [],
        auxiliaryFields: [],
        backFields: []
      },
      barcodes: [{
        format: "PKBarcodeFormatQR",
        message: "hello",
        messageEncoding: "iso-8859-1"
      }]
    }
  end

  # ---- Top-level shape ----

  def test_validate_returns_empty_for_minimal_valid_pass
    assert_equal [], Passkit::Validator.validate(base_pass)
  end

  def test_validate_bang_does_not_raise_on_valid_pass
    assert_nothing_raised { Passkit::Validator.validate!(base_pass) }
  end

  def test_validate_returns_error_when_input_is_not_hash
    assert_equal ["pass must be a Hash"], Passkit::Validator.validate("nope")
    assert_equal ["pass must be a Hash"], Passkit::Validator.validate(nil)
    assert_equal ["pass must be a Hash"], Passkit::Validator.validate([])
  end

  def test_validate_bang_raises_validation_error_with_messages_joined
    err = assert_raises(Passkit::ValidationError) do
      pass = base_pass
      pass.delete(:formatVersion)
      pass.delete(:description)
      Passkit::Validator.validate!(pass)
    end
    assert_match(/formatVersion is required/, err.message)
    assert_match(/description is required/, err.message)
    assert_includes err.message, ";"
  end

  # ---- Required top-level keys ----

  %i[formatVersion teamIdentifier passTypeIdentifier serialNumber organizationName description].each do |key|
    define_method("test_required_top_level_#{key}_missing") do
      pass = base_pass
      pass.delete(key)
      assert_includes Passkit::Validator.validate(pass), "#{key} is required"
    end

    define_method("test_required_top_level_#{key}_empty_string_rejected") do
      pass = base_pass.merge(key => "")
      assert_includes Passkit::Validator.validate(pass), "#{key} is required"
    end
  end

  # ---- formatVersion ----

  def test_format_version_must_be_integer
    pass = base_pass.merge(formatVersion: "1")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("formatVersion must be Integer") }, errors.inspect
  end

  def test_format_version_accepts_integer
    pass = base_pass.merge(formatVersion: 2)
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- Colors ----

  def test_color_regex_accepts_zero_padded_and_spaced
    pass = base_pass.merge(backgroundColor: "rgb(0, 0, 0)", foregroundColor: "rgb(255,255,255)")
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_color_regex_rejects_hex
    pass = base_pass.merge(backgroundColor: "#ffffff")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("backgroundColor must match rgb(r, g, b)") }
  end

  def test_color_regex_rejects_rgba
    pass = base_pass.merge(labelColor: "rgba(0, 0, 0, 0.5)")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("labelColor must match rgb(r, g, b)") }
  end

  def test_color_regex_rejects_non_string
    pass = base_pass.merge(foregroundColor: 0)
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("foregroundColor must match rgb(r, g, b)") }
  end

  def test_footer_background_color_validates_when_present
    pass = base_pass.merge(footerBackgroundColor: "not-a-color")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("footerBackgroundColor") }
  end

  # ---- URLs ----

  def test_web_service_url_must_be_https
    pass = base_pass.merge(webServiceURL: "http://example.com/passkit/api")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("webServiceURL must start with https://") }
  end

  def test_venue_urls_must_be_http_or_https
    pass = base_pass.merge(bagPolicyURL: "ftp://example.com/bag")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("bagPolicyURL must be an http(s) URL") }
  end

  def test_app_launch_url_accepts_custom_scheme
    pass = base_pass.merge(appLaunchURL: "myapp://launch")
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- Booleans ----

  def test_sharing_prohibited_must_be_boolean
    pass = base_pass.merge(sharingProhibited: "true")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("sharingProhibited must be boolean") }
  end

  def test_use_automatic_colors_must_be_boolean_when_set
    pass = base_pass.merge(useAutomaticColors: "yes")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("useAutomaticColors must be boolean") }
  end

  def test_use_automatic_colors_accepts_boolean
    pass = base_pass.merge(useAutomaticColors: true)
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- ISO 8601 dates ----

  def test_expiration_date_accepts_iso8601_with_offset
    pass = base_pass.merge(expirationDate: "2030-01-01T12:00:00+00:00")
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_expiration_date_rejects_unix_timestamp
    pass = base_pass.merge(expirationDate: "1893456000")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("expirationDate is not valid ISO 8601") }
  end

  def test_expiration_date_rejects_non_string
    pass = base_pass.merge(expirationDate: Time.utc(2030, 1, 1))
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("expirationDate must be an ISO 8601 string") }
  end

  # ---- Pass type block ----

  def test_pass_type_block_required
    pass = base_pass
    pass.delete(:storeCard)
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("must include one of") }
  end

  def test_multiple_pass_type_blocks_rejected
    pass = base_pass.merge(eventTicket: {})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("multiple pass-type blocks") }
  end

  def test_field_block_must_be_array
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(headerFields: "nope")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("storeCard.headerFields must be an Array") }
  end

  def test_field_requires_key_and_value
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(primaryFields: [{label: "x"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("primaryFields[0].key is required") }
    assert errors.any? { |e| e.include?("primaryFields[0].value is required") }
  end

  def test_field_validates_date_style_enum
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(secondaryFields: [{key: "k", value: "v", dateStyle: "PKDateStyleBogus"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("secondaryFields[0].dateStyle") }
  end

  def test_field_validates_text_alignment_enum
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(secondaryFields: [{key: "k", value: "v", textAlignment: "left"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("secondaryFields[0].textAlignment") }
  end

  def test_field_validates_data_detector_types_array
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(backFields: [{key: "k", value: "v", dataDetectorTypes: ["bogus"]}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("backFields[0].dataDetectorTypes") }
  end

  def test_field_per_field_semantics_validated
    pass = base_pass
    pass[:storeCard] = pass[:storeCard].merge(secondaryFields: [
      {key: "k", value: "v", semantics: {eventType: "PKEventTypeBogus"}}
    ])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("secondaryFields[0].semantics.eventType") }
  end

  def test_boarding_pass_transit_type_enum
    pass = base_pass
    pass.delete(:storeCard)
    pass[:boardingPass] = {
      headerFields: [], primaryFields: [], secondaryFields: [], auxiliaryFields: [], backFields: [],
      transitType: "PKTransitTypeRocket"
    }
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("boardingPass.transitType") }
  end

  # ---- Locations ----

  def test_locations_must_be_array
    pass = base_pass.merge(locations: "nope")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("locations must be an Array") }
  end

  def test_location_requires_lat_lon
    pass = base_pass.merge(locations: [{relevantText: "Gate A"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("locations[0].latitude is required") }
    assert errors.any? { |e| e.include?("locations[0].longitude is required") }
  end

  def test_location_lat_lon_must_be_numeric
    pass = base_pass.merge(locations: [{latitude: "41.2", longitude: "-95.9"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("locations[0].latitude must be Numeric") }
  end

  # ---- Beacons ----

  def test_beacons_require_proximity_uuid
    pass = base_pass.merge(beacons: [{major: 1}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("beacons[0].proximityUUID is required") }
  end

  # ---- Barcodes ----

  [
    [{format: "PKBarcodeFormatPDF417", message: "x", messageEncoding: "iso-8859-1"}, []],
    [{format: "PKBarcodeFormatBogus", message: "x", messageEncoding: "iso-8859-1"}, ["barcodes[0].format"]],
    [{message: "x", messageEncoding: "iso-8859-1"}, ["barcodes[0].format is required"]],
    [{format: "PKBarcodeFormatQR", messageEncoding: "iso-8859-1"}, ["barcodes[0].message is required"]],
    [{format: "PKBarcodeFormatQR", message: "x"}, ["barcodes[0].messageEncoding is required"]]
  ].each_with_index do |(barcode, expected_substrings), i|
    define_method("test_barcode_case_#{i}") do
      pass = base_pass.merge(barcodes: [barcode])
      errors = Passkit::Validator.validate(pass)
      if expected_substrings.empty?
        assert_equal [], errors
      else
        expected_substrings.each do |sub|
          assert errors.any? { |e| e.include?(sub) }, "expected #{sub.inspect} in #{errors.inspect}"
        end
      end
    end
  end

  def test_singular_barcode_validated_too
    pass = base_pass
    pass.delete(:barcodes)
    pass[:barcode] = {format: "PKBarcodeFormatBogus", message: "x", messageEncoding: "iso-8859-1"}
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("barcode.format") }
  end

  # ---- Store identifiers ----

  def test_associated_store_identifiers_must_be_integers
    pass = base_pass.merge(associatedStoreIdentifiers: ["123"])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("associatedStoreIdentifiers[0] must be Integer") }
  end

  def test_auxiliary_store_identifiers_must_be_integers
    pass = base_pass.merge(auxiliaryStoreIdentifiers: ["456"])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("auxiliaryStoreIdentifiers[0] must be Integer") }
  end

  # ---- NFC ----

  def test_nfc_requires_message_and_encryption_public_key
    pass = base_pass.merge(nfc: {})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("nfc.message is required") }
    assert errors.any? { |e| e.include?("nfc.encryptionPublicKey is required") }
  end

  def test_nfc_requires_authentication_must_be_boolean
    pass = base_pass.merge(nfc: {message: "m", encryptionPublicKey: "k", requiresAuthentication: "yes"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("nfc.requiresAuthentication must be boolean") }
  end

  def test_nfc_complete_passes
    pass = base_pass.merge(nfc: {message: "m", encryptionPublicKey: "k", requiresAuthentication: true})
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- preferredStyleSchemes (iOS 18+) ----

  def test_preferred_style_schemes_accepts_every_apple_scheme
    %w[posterEventTicket eventTicket semanticBoardingPass boardingPass].each do |scheme|
      pass = base_pass.merge(preferredStyleSchemes: [scheme])
      assert_equal [], Passkit::Validator.validate(pass), scheme
    end
  end

  def test_preferred_style_schemes_rejects_unknown_value
    pass = base_pass.merge(preferredStyleSchemes: ["bogus"])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("preferredStyleSchemes contains unknown value") }
  end

  def test_preferred_style_schemes_must_be_array
    pass = base_pass.merge(preferredStyleSchemes: "posterEventTicket")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("preferredStyleSchemes must be an Array") }
  end

  # ---- additionalInfoFields ----

  # Apple's PassFields holds additionalInfoFields beside backFields. At the
  # top level of pass.json Wallet ignores it, so the validator refuses it.
  def test_additional_info_fields_at_top_level_is_misplaced
    pass = base_pass.merge(additionalInfoFields: [{key: "doors", value: "7pm"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("additionalInfoFields belongs inside the pass style block") }
  end

  def test_additional_info_fields_validated_as_pass_field_content
    pass = base_pass
    pass[:storeCard][:additionalInfoFields] = [{label: "no key or value"}]
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("storeCard.additionalInfoFields[0].key is required") }
    assert errors.any? { |e| e.include?("storeCard.additionalInfoFields[0].value is required") }
  end

  def test_additional_info_fields_must_be_array
    pass = base_pass
    pass[:storeCard][:additionalInfoFields] = {key: "x", value: "y"}
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("storeCard.additionalInfoFields must be an Array") }
  end

  # ---- relevantDates (iOS 18+) ----

  def test_relevant_dates_accepts_single_instant
    pass = base_pass.merge(relevantDates: [{startDate: "2030-01-01T12:00:00+00:00"}])
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_relevant_dates_accepts_window_under_24h
    pass = base_pass.merge(relevantDates: [{
      startDate: "2030-01-01T12:00:00+00:00",
      endDate: "2030-01-01T18:00:00+00:00"
    }])
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_relevant_dates_rejects_window_over_24h
    pass = base_pass.merge(relevantDates: [{
      startDate: "2030-01-01T00:00:00+00:00",
      endDate: "2030-01-02T01:00:00+00:00"
    }])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("window exceeds Apple's 24h cap") }
  end

  def test_relevant_dates_rejects_end_before_start
    pass = base_pass.merge(relevantDates: [{
      startDate: "2030-01-01T18:00:00+00:00",
      endDate: "2030-01-01T12:00:00+00:00"
    }])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("endDate must be >= startDate") }
  end

  def test_relevant_dates_requires_date_or_start_date
    pass = base_pass.merge(relevantDates: [{endDate: "2030-01-01T12:00:00+00:00"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("relevantDates[0] needs date or startDate") }
  end

  # Apple's RelevantDate takes a single `date` as well as a start/end window.
  def test_relevant_dates_accepts_single_date_key
    pass = base_pass.merge(relevantDates: [{date: "2030-01-01T12:00:00+00:00"}])
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_relevant_dates_rejects_invalid_date_key
    pass = base_pass.merge(relevantDates: [{date: "soon"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("relevantDates[0].date is not valid ISO 8601") }
  end

  def test_relevant_dates_rejects_invalid_iso
    pass = base_pass.merge(relevantDates: [{startDate: "not-a-date"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("startDate is not valid ISO 8601") }
  end

  # ---- Semantics ----

  def test_semantics_event_type_enum
    pass = base_pass.merge(semantics: {eventType: "PKEventTypeBogus"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.eventType") }
  end

  Passkit::Validator::EVENT_TYPES.each do |et|
    define_method("test_semantics_event_type_accepts_#{et}") do
      pass = base_pass.merge(semantics: {eventType: et})
      assert_equal [], Passkit::Validator.validate(pass)
    end
  end

  def test_semantics_unknown_keys_are_allowed
    pass = base_pass.merge(semantics: {someBrandNewKeyAppleAdded: "value"})
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_semantics_event_start_date_must_be_iso8601
    pass = base_pass.merge(semantics: {eventStartDate: "not a date"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.eventStartDate is not valid ISO 8601") }
  end

  def test_semantics_event_name_must_be_string
    pass = base_pass.merge(semantics: {eventName: 123})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.eventName must be String") }
  end

  def test_semantics_silence_requested_must_be_boolean
    pass = base_pass.merge(semantics: {silenceRequested: "true"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.silenceRequested must be boolean") }
  end

  # Apple's model types duration as Int (seconds).
  def test_semantics_duration_must_be_integer
    pass = base_pass.merge(semantics: {duration: "two hours"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.duration must be Integer") }
  end

  def test_semantics_performer_names_must_be_string_array
    pass = base_pass.merge(semantics: {performerNames: ["valid", 42]})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.performerNames must be Array of String") }
  end

  # ---- Semantic sub-objects ----

  def test_semantics_venue_location_requires_lat_lon
    pass = base_pass.merge(semantics: {venueLocation: {altitude: 100}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.venueLocation.latitude is required") }
    assert errors.any? { |e| e.include?("semantics.venueLocation.longitude is required") }
  end

  # Apple's semantics model types venueEntrance as a String (the entrance's
  # name), not a location.
  def test_semantics_venue_entrance_is_a_string
    assert_equal [], Passkit::Validator.validate(base_pass.merge(semantics: {venueEntrance: "Gate A"}))
    errors = Passkit::Validator.validate(base_pass.merge(semantics: {venueEntrance: {latitude: 40.0, longitude: -74.0}}))
    assert errors.any? { |e| e.include?("semantics.venueEntrance must be String") }
  end

  def test_semantics_total_price_requires_amount_and_currency
    pass = base_pass.merge(semantics: {totalPrice: {amount: "10.00"}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.totalPrice.currencyCode") }
  end

  def test_semantics_total_price_currency_must_be_three_letters
    pass = base_pass.merge(semantics: {totalPrice: {amount: "10.00", currencyCode: "DOLLARS"}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("currencyCode must be a 3-letter ISO 4217 code") }
  end

  def test_semantics_passenger_name_validates_string_components
    pass = base_pass.merge(semantics: {passengerName: {givenName: 1}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.passengerName.givenName must be String") }
  end

  def test_semantics_event_start_date_info_validates_shape
    pass = base_pass.merge(semantics: {eventStartDateInfo: {date: "bad", unannounced: "true"}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("eventStartDateInfo.date is not valid ISO 8601") }
    assert errors.any? { |e| e.include?("eventStartDateInfo.unannounced must be boolean") }
  end

  def test_semantics_seats_must_be_array
    pass = base_pass.merge(semantics: {seats: {seatRow: "1"}})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.seats must be an Array") }
  end

  def test_semantics_seat_validates_string_fields
    pass = base_pass.merge(semantics: {seats: [{seatRow: 12}]})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.seats[0].seatRow must be String") }
  end

  def test_semantics_seat_section_color_validates_rgb
    pass = base_pass.merge(semantics: {seats: [{seatSectionColor: "blue"}]})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("seatSectionColor must match rgb(r, g, b)") }
  end

  def test_semantics_wifi_access_requires_ssid_and_password
    pass = base_pass.merge(semantics: {wifiAccess: [{}]})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("wifiAccess[0].ssid is required") }
    assert errors.any? { |e| e.include?("wifiAccess[0].password is required") }
  end

  # ---- fetch must not collapse explicit false values ----

  def test_explicit_false_boolean_value_is_visible_to_type_check
    # Regression: a previous `hash[key] || hash[key.to_s]` implementation
    # treated `{sharingProhibited: false}` as absent, silently skipping the
    # boolean type check. A subclass returning `"false"` (string) for the
    # same key must therefore be REJECTED, not silently accepted.
    pass = base_pass.merge(sharingProhibited: "false")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("sharingProhibited must be boolean") },
      "validator must catch invalid value even when canonical default is `false`"
  end

  def test_explicit_false_value_passes_when_actually_boolean
    pass = base_pass.merge(sharingProhibited: false, voided: false, suppressStripShine: false)
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_use_automatic_colors_explicit_false_validates_when_boolean
    pass = base_pass.merge(useAutomaticColors: false)
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_use_automatic_colors_explicit_string_false_is_rejected
    pass = base_pass.merge(useAutomaticColors: "false")
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("useAutomaticColors must be boolean") }
  end

  def test_nfc_requires_authentication_explicit_false_passes
    pass = base_pass.merge(nfc: {message: "m", encryptionPublicKey: "k", requiresAuthentication: false})
    assert_equal [], Passkit::Validator.validate(pass)
  end

  def test_nfc_requires_authentication_string_false_rejected
    pass = base_pass.merge(nfc: {message: "m", encryptionPublicKey: "k", requiresAuthentication: "false"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("nfc.requiresAuthentication must be boolean") }
  end

  def test_event_date_info_unannounced_explicit_false_passes
    pass = base_pass.merge(semantics: {eventStartDateInfo: {unannounced: false, undetermined: false}})
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- String-keyed inputs (some callers pass JSON-decoded hashes) ----

  def test_validator_handles_string_keys
    pass = {
      "formatVersion" => 1,
      "teamIdentifier" => "ABC1234567",
      "passTypeIdentifier" => "pass.com.example.test",
      "serialNumber" => "abc-123",
      "organizationName" => "Acme",
      "description" => "Test pass",
      "foregroundColor" => "rgb(0, 0, 0)",
      "backgroundColor" => "rgb(255, 255, 255)",
      "labelColor" => "rgb(0, 0, 0)",
      "webServiceURL" => "https://example.com/passkit/api",
      "sharingProhibited" => false,
      "suppressStripShine" => true,
      "voided" => false,
      "storeCard" => {
        "headerFields" => [], "primaryFields" => [], "secondaryFields" => [],
        "auxiliaryFields" => [], "backFields" => []
      },
      "barcodes" => [{
        "format" => "PKBarcodeFormatQR",
        "message" => "hello",
        "messageEncoding" => "iso-8859-1"
      }]
    }
    assert_equal [], Passkit::Validator.validate(pass)
  end

  # ---- Multiple errors aggregated ----

  def test_multiple_errors_aggregated_into_single_response
    pass = base_pass.merge(
      formatVersion: "1",
      backgroundColor: "blue",
      preferredStyleSchemes: ["bogus"],
      semantics: {eventType: "PKEventTypeBogus"}
    )
    errors = Passkit::Validator.validate(pass)
    assert errors.size >= 4
    assert errors.any? { |e| e.include?("formatVersion") }
    assert errors.any? { |e| e.include?("backgroundColor") }
    assert errors.any? { |e| e.include?("preferredStyleSchemes") }
    assert errors.any? { |e| e.include?("semantics.eventType") }
  end

  # ---- Apple pass-builder parity (Validation/Validators, WWDC26) ----

  def event_ticket_pass(**overrides)
    pass = base_pass
    pass.delete(:storeCard)
    pass[:eventTicket] = {headerFields: [], primaryFields: [], secondaryFields: [], auxiliaryFields: [], backFields: []}
    pass.merge(overrides)
  end

  POSTER_SEMANTICS = {eventName: "Show", venueName: "Hall"}.freeze
  POSTER_NFC = {message: "m", encryptionPublicKey: "k", requiresAuthentication: false}.freeze

  # Apple's EventTicketValidator errors, applied when an eventTicket lists the
  # posterEventTicket scheme. Each row drops one requirement.
  [
    [{semantics: POSTER_SEMANTICS}, ["posterEventTicket needs nfc"]],
    [{semantics: POSTER_SEMANTICS, nfc: POSTER_NFC.except(:requiresAuthentication)}, ["posterEventTicket needs nfc.requiresAuthentication"]],
    [{semantics: POSTER_SEMANTICS.except(:eventName), nfc: POSTER_NFC}, ["posterEventTicket needs semantics.eventName"]],
    [{semantics: POSTER_SEMANTICS.except(:venueName), nfc: POSTER_NFC}, ["posterEventTicket needs semantics.venueName"]],
    [{semantics: POSTER_SEMANTICS.merge(eventType: "PKEventTypeSports"), nfc: POSTER_NFC},
      ["needs semantics.awayTeamAbbreviation", "needs semantics.homeTeamAbbreviation"]],
    [{semantics: POSTER_SEMANTICS.merge(eventType: "PKEventTypeLivePerformance"), nfc: POSTER_NFC}, ["needs semantics.performerNames"]],
    [{semantics: POSTER_SEMANTICS, nfc: POSTER_NFC}, []]
  ].each_with_index do |(overrides, expected), i|
    define_method(:"test_poster_event_ticket_requirements_#{i}") do
      pass = event_ticket_pass(preferredStyleSchemes: %w[posterEventTicket eventTicket], **overrides)
      errors = Passkit::Validator.validate(pass, files: %w[icon.png artwork.png])
      expected.each { |msg| assert errors.any? { |e| e.include?(msg) }, "expected #{msg.inspect} in #{errors.inspect}" }
      assert_empty errors if expected.empty?
    end
  end

  def test_poster_event_ticket_needs_artwork_or_background_image
    pass = event_ticket_pass(preferredStyleSchemes: ["posterEventTicket"], semantics: POSTER_SEMANTICS, nfc: POSTER_NFC)
    errors = Passkit::Validator.validate(pass, files: %w[icon.png logo.png])
    assert errors.any? { |e| e.include?("posterEventTicket needs an artwork or background image") }
    assert_empty Passkit::Validator.validate(pass, files: %w[icon.png background@2x.png])
  end

  # A legacy event ticket has none of the poster requirements.
  def test_event_ticket_without_poster_scheme_skips_poster_rules
    assert_empty Passkit::Validator.validate(event_ticket_pass, files: %w[icon.png])
  end

  def test_icon_is_required_when_files_are_given
    errors = Passkit::Validator.validate(base_pass, files: %w[logo.png icon@2x.png])
    assert errors.any? { |e| e.include?("icon.png is required") }
  end

  def test_files_are_not_checked_when_not_given
    assert_empty Passkit::Validator.validate(base_pass)
  end

  def test_barcodes_accept_every_ios_27_format
    %w[PKBarcodeFormatCode39 PKBarcodeFormatCodabar PKBarcodeFormatEAN13 PKBarcodeFormatI2of5].each do |format|
      pass = base_pass.merge(barcodes: [{format: format, message: "123456", messageEncoding: "iso-8859-1"}])
      assert_empty Passkit::Validator.validate(pass), format
    end
  end

  # Apple's semantics model: flightNumber Int, boardingSequenceNumber String.
  [
    [{flightNumber: 815}, nil],
    [{flightNumber: "815"}, "semantics.flightNumber must be Integer"],
    [{boardingSequenceNumber: "12"}, nil],
    [{boardingSequenceNumber: 12}, "semantics.boardingSequenceNumber must be String"],
    [{venueEntranceGate: "B"}, nil],
    [{venueEntranceGate: 2}, "semantics.venueEntranceGate must be String"],
    [{departureTerminal: 4}, "semantics.departureTerminal must be String"]
  ].each_with_index do |(semantics, error), i|
    define_method(:"test_semantics_types_match_apple_#{i}") do
      errors = Passkit::Validator.validate(base_pass.merge(semantics: semantics))
      if error
        assert errors.any? { |e| e.include?(error) }, "expected #{error.inspect} in #{errors.inspect}"
      else
        assert_empty errors
      end
    end
  end

  # Wallet refuses a pass whose fields repeat a key.
  def test_field_keys_must_be_unique_within_a_style_block
    pass = base_pass
    pass[:storeCard][:primaryFields] = [{key: "name", value: "A"}]
    pass[:storeCard][:backFields] = [{key: "name", value: "B"}]
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("duplicate field key \"name\"") }
  end

  def test_change_message_must_contain_placeholder
    pass = base_pass
    pass[:storeCard][:primaryFields] = [{key: "a", value: "x", changeMessage: "Changed"}]
    assert Passkit::Validator.validate(pass).any? { |e| e.include?("changeMessage must contain %@") }
    pass[:storeCard][:primaryFields] = [{key: "a", value: "x", changeMessage: "Now %@"}]
    assert_empty Passkit::Validator.validate(pass)
  end

  def test_date_formatted_field_needs_an_iso_8601_value
    pass = base_pass
    pass[:storeCard][:secondaryFields] = [{key: "when", value: "Tonight", dateStyle: "PKDateStyleShort"}]
    assert Passkit::Validator.validate(pass).any? { |e| e.include?("storeCard.secondaryFields[0].value must be ISO 8601") }
    pass[:storeCard][:secondaryFields] = [{key: "when", value: "2030-01-01T19:00:00-05:00", timeStyle: "PKDateStyleShort", ignoresTimeZone: true}]
    assert_empty Passkit::Validator.validate(pass)
  end

  def test_field_boolean_flags_and_currency_code
    pass = base_pass
    pass[:storeCard][:primaryFields] = [{key: "a", value: 5, ignoresTimeZone: "yes", isRelative: 1, currencyCode: "dollars"}]
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("ignoresTimeZone must be boolean") }
    assert errors.any? { |e| e.include?("isRelative must be boolean") }
    assert errors.any? { |e| e.include?("currencyCode must be a 3-letter") }
  end

  # ---- featuredActions (iOS 27) ----

  # The shapes Wallet's own validator accepts: every type but call and place
  # with an http(s) url, call with a tel: url, place with a placeIdentifier.
  (Passkit::Validator::FEATURED_ACTION_TYPES - %w[call place]).each do |type|
    define_method(:"test_featured_action_#{type}_accepts_an_http_url") do
      actions = [{identifier: "a", type: type, url: "https://example.com/#{type}"}]
      assert_empty Passkit::Validator.validate(base_pass.merge(featuredActions: actions))
    end
  end

  def test_featured_actions_accept_call_with_tel_and_place_with_a_place_id
    actions = [
      {identifier: "phone", type: "call", url: "tel:+15555550100"},
      {identifier: "map", type: "place", placeIdentifier: "I63802885C8189B2B"}
    ]
    assert_empty Passkit::Validator.validate(base_pass.merge(featuredActions: actions))
  end

  [
    [[{identifier: "a", type: "bogus", url: "https://x.test"}], "featuredActions[0].type must be one of"],
    [[{type: "call", url: "tel:+15555550100"}], "featuredActions[0].identifier is required"],
    # Wallet rejects these three (iOS 27 "not a valid featured action").
    [[{identifier: "a", type: "place", url: "https://maps.apple.com/?q=Hall"}], "featuredActions[0].placeIdentifier (an Apple Maps place ID) is required"],
    [[{identifier: "a", type: "call", url: "https://x.test"}], "featuredActions[0].url must be a tel: URL"],
    [[{identifier: "a", type: "shop", url: "eventrise://shop"}], "featuredActions[0].url must be an http(s) URL"],
    [[{identifier: "a", type: "viewSchedule"}], "featuredActions[0].url must be an http(s) URL"],
    [[{identifier: "a", type: "shop", url: "not a url"}], "featuredActions[0].url must be an http(s) URL"],
    [[{identifier: "a", type: "shop", url: "https:example.com"}], "featuredActions[0].url must be an http(s) URL"],
    [[{identifier: "a", type: "call", url: "tel:"}], "featuredActions[0].url must be a tel: URL"],
    [[{identifier: "a", type: "place", placeIdentifier: "I63802885C8189B2B", url: "not a url"}], "featuredActions[0].url must be an absolute URL"],
    [[{identifier: "a", type: "call", url: "tel:1"}, {identifier: "a", type: "shop", url: "https://x.test"}], "featuredActions identifiers must be unique"],
    [Array.new(3) { |n| {identifier: "a#{n}", type: "shop", url: "https://x.test"} }, "featuredActions holds at most 2"],
    [{identifier: "a", type: "shop"}, "featuredActions must be an Array"]
  ].each_with_index do |(actions, error), i|
    define_method(:"test_featured_actions_rejects_#{i}") do
      errors = Passkit::Validator.validate(base_pass.merge(featuredActions: actions))
      assert errors.any? { |e| e.include?(error) }, "expected #{error.inspect} in #{errors.inspect}"
    end
  end

  # ---- posterGeneric (iOS 27) ----

  def test_poster_generic_is_validated_and_needs_a_legacy_style
    poster = {headerFields: [{key: "h", value: "x"}], footerFields: [{label: "no key"}]}
    errors = Passkit::Validator.validate(base_pass.merge(posterGeneric: poster))
    assert errors.any? { |e| e.include?("posterGeneric.footerFields[0].key is required") }

    alone = base_pass.merge(posterGeneric: {headerFields: []})
    alone.delete(:storeCard)
    errors = Passkit::Validator.validate(alone)
    assert errors.any? { |e| e.include?("pass must include one of") }, "posterGeneric alone leaves iOS 26 with nothing to show"
  end

  # posterGeneric repeats the legacy block's fields by design, so keys only
  # have to be unique within each block.
  def test_poster_generic_may_reuse_the_legacy_keys
    pass = base_pass
    pass[:storeCard][:primaryFields] = [{key: "name", value: "Ana"}]
    pass[:posterGeneric] = {primaryFields: [{key: "name", value: "Ana"}]}
    assert_empty Passkit::Validator.validate(pass)
  end

  # ---- limits and other top-level keys ----

  def test_locations_and_beacons_hold_at_most_ten
    locations = Array.new(11) { {latitude: 1.0, longitude: 2.0} }
    beacons = Array.new(11) { {proximityUUID: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0"} }
    errors = Passkit::Validator.validate(base_pass.merge(locations: locations, beacons: beacons))
    assert errors.any? { |e| e.include?("locations holds at most 10") }
    assert errors.any? { |e| e.include?("beacons holds at most 10") }
  end

  def test_max_distance_and_suppress_header_darkening_types
    errors = Passkit::Validator.validate(base_pass.merge(maxDistance: "far", suppressHeaderDarkening: "no"))
    assert errors.any? { |e| e.include?("maxDistance must be a non-negative number") }
    assert errors.any? { |e| e.include?("suppressHeaderDarkening must be boolean") }
  end

  def test_upcoming_pass_information_entries
    good = [{identifier: "s1", name: "Keynote", type: "event", isActive: true}]
    assert_empty Passkit::Validator.validate(base_pass.merge(upcomingPassInformation: good))
    errors = Passkit::Validator.validate(base_pass.merge(upcomingPassInformation: [{name: "x", isActive: "y"}]))
    assert errors.any? { |e| e.include?("upcomingPassInformation[0].identifier is required") }
    assert errors.any? { |e| e.include?("upcomingPassInformation[0].isActive must be boolean") }
  end
end
