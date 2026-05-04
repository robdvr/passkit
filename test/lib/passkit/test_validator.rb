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

  def test_preferred_style_schemes_accepts_known_value
    pass = base_pass.merge(preferredStyleSchemes: ["posterEventTicket"])
    assert_equal [], Passkit::Validator.validate(pass)
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

  def test_additional_info_fields_validated_as_pass_field_content
    pass = base_pass.merge(additionalInfoFields: [{label: "no key or value"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("additionalInfoFields[0].key is required") }
    assert errors.any? { |e| e.include?("additionalInfoFields[0].value is required") }
  end

  def test_additional_info_fields_must_be_array
    pass = base_pass.merge(additionalInfoFields: {key: "x", value: "y"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("additionalInfoFields must be an Array") }
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

  def test_relevant_dates_requires_start_date
    pass = base_pass.merge(relevantDates: [{endDate: "2030-01-01T12:00:00+00:00"}])
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("startDate is required") }
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

  def test_semantics_duration_must_be_numeric
    pass = base_pass.merge(semantics: {duration: "two hours"})
    errors = Passkit::Validator.validate(pass)
    assert errors.any? { |e| e.include?("semantics.duration must be Numeric") }
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

  def test_semantics_venue_entrance_lat_lon_optional
    pass = base_pass.merge(semantics: {venueEntrance: {latitude: 40.0, longitude: -74.0}})
    assert_equal [], Passkit::Validator.validate(pass)
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
end
