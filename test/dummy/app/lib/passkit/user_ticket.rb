module Passkit
  # Example eventTicket pass demonstrating the iOS 18+ enhanced (poster-style)
  # layout. Opts in via `preferred_style_schemes`, populates the venue utility
  # URLs and `additional_info_fields` for the detail view, and provides the
  # full set of Apple typed event semantics required for lock-screen surfacing,
  # the Smart Stack widget, Live Activities, and Siri prompts.
  #
  # iOS ≤17 ignores the iOS 18+ keys and renders the legacy layout from the
  # existing `header_fields`/`primary_fields`/`secondary_fields` arrays — both
  # paths are populated for backwards compatibility.
  #
  # Host apps should subclass this pattern, not BasePass directly, when
  # building event passes.
  class UserTicket < BasePass
    EVENT_NAME = "Sample Event".freeze
    EVENT_LOGO_TEXT = "SAMPLE FEST".freeze
    VENUE_NAME = "Sample Venue".freeze
    VENUE_LAT = 41.22476226066285
    VENUE_LON = -95.92879374051269

    def pass_type
      :eventTicket
    end

    def organization_name
      "Passkit"
    end

    def description
      "Event ticket for #{EVENT_NAME}"
    end

    # iOS 18+ poster-style layout opt-in. iOS ≤17 ignores this key.
    def preferred_style_schemes
      ["posterEventTicket"]
    end

    # iOS 18+ branded text shown next to the event logo on the poster face.
    def event_logo_text
      EVENT_LOGO_TEXT
    end

    # Apple uses these to surface the pass on the lock screen near the venue.
    # Up to 10 entries; pair with `max_distance` (meters) to tighten the radius.
    def locations
      [
        {latitude: 41.2273414693647, longitude: -95.92925748878405, relevantText: "North Entrance"},
        {latitude: VENUE_LAT, longitude: VENUE_LON, relevantText: "Main Entrance"}
      ]
    end

    def max_distance
      500
    end

    def file_name
      @file_name ||= SecureRandom.uuid
    end

    def barcodes
      [{
        messageEncoding: "iso-8859-1",
        format: "PKBarcodeFormatQR",
        message: "ticket-#{@generator&.id}",
        altText: "Ticket ##{@generator&.id}"
      }]
    end

    def logo_text
      EVENT_NAME
    end

    # iOS ≤17 — single instant for lock-screen relevance.
    def relevant_date
      event_start.iso8601
    end

    # iOS 18+ — array of relevance windows (each capped at 24h by Apple).
    # Both `relevant_date` and `relevant_dates` may be set; iOS 18+ prefers
    # the plural form.
    def relevant_dates
      [{startDate: event_start.iso8601, endDate: (event_start + 4.hours).iso8601}]
    end

    def expiration_date
      (event_start + 4.hours).iso8601
    end

    # Group multi-ticket purchases so they collapse into one stack in Wallet.
    def grouping_identifier
      return nil unless @generator.respond_to?(:user_id)
      "user-#{@generator.user_id}"
    end

    # iOS 18+ supplementary rows in the detail view (parking, food, etc.).
    def additional_info_fields
      [
        {key: "doors", label: "DOORS", value: (event_start - 1.hour).iso8601,
         dateStyle: "PKDateStyleNone", timeStyle: "PKDateStyleShort"},
        {key: "duration", label: "DURATION", value: "Approx. 3 hours"}
      ]
    end

    # Venue utility URLs (iOS 18+) — surface as tappable rows.
    def bag_policy_url
      "https://example.com/venue/bag-policy"
    end

    def parking_information_url
      "https://example.com/venue/parking"
    end

    def merchandise_url
      "https://example.com/event/merch"
    end

    def contact_venue_email
      "venue@example.com"
    end

    def contact_venue_phone_number
      "+15555550100"
    end

    def contact_venue_website
      "https://example.com/venue"
    end

    # Apple typed event semantics. Without these, the lock screen, Smart
    # Stack, Live Activities, and Siri ("you have a ticket coming up")
    # integrations don't fire — they key off these specific tags, not the
    # field arrays.
    # @see https://developer.apple.com/documentation/walletpasses/semantictags
    def semantics
      {
        eventType: "PKEventTypeLivePerformance",
        eventName: EVENT_NAME,
        genre: "Live Performance",
        venueName: VENUE_NAME,
        venueLocation: {latitude: VENUE_LAT, longitude: VENUE_LON},
        venueEntrance: {latitude: 41.2273414693647, longitude: -95.92925748878405},
        venueDoorsOpenDate: (event_start - 1.hour).iso8601,
        eventStartDate: event_start.iso8601,
        eventEndDate: (event_start + 3.hours).iso8601,
        performerNames: ["Sample Performer"],
        attendeeName: @generator&.name.to_s,
        admissionLevel: "General Admission",
        admissionLevelAbbreviation: "GA",
        seats: [{seatSection: "A", seatRow: "12", seatNumber: "5", seatType: "Reserved"}]
      }
    end

    # eventTicket layout convention: ≤1 primaryField, ≤4 secondary, ≤4
    # auxiliary. The gem does not enforce these limits — Apple's renderer
    # just truncates extras.
    def primary_fields
      [{key: "event", label: "EVENT", value: EVENT_NAME}]
    end

    def secondary_fields
      [
        {
          key: "doors",
          label: "DOORS",
          value: event_start.iso8601,
          dateStyle: "PKDateStyleNone",
          timeStyle: "PKDateStyleShort"
        },
        {key: "seat", label: "SEAT", value: "A 12 / 5"}
      ]
    end

    def auxiliary_fields
      [
        {key: "holder", label: "HOLDER", value: @generator&.name.to_s},
        {key: "venue", label: "VENUE", value: VENUE_NAME}
      ]
    end

    def back_fields
      [
        {
          key: "doors_full",
          label: "Doors open",
          value: event_start.iso8601,
          dateStyle: "PKDateStyleMedium",
          timeStyle: "PKDateStyleShort"
        },
        {key: "ticket_id", label: "Ticket", value: @generator&.id.to_s},
        {key: "support", label: "Support", value: "support@example.com"}
      ]
    end

    # Localized labels — Wallet substitutes field `value`s that match a key
    # at render time per the device language. Ships English + Spanish so the
    # localization pipeline has integration-test coverage.
    def localized_strings
      {
        en: {
          "EVENT" => "Event",
          "DOORS" => "Doors",
          "SEAT" => "Seat",
          "HOLDER" => "Holder",
          "VENUE" => "Venue",
          "DURATION" => "Duration"
        },
        es: {
          "EVENT" => "Evento",
          "DOORS" => "Puertas",
          "SEAT" => "Asiento",
          "HOLDER" => "Titular",
          "VENUE" => "Sede",
          "DURATION" => "Duración"
        }
      }
    end

    private

    def event_start
      @event_start ||= Time.current.beginning_of_day + 7.days + 19.hours
    end

    def folder_name
      "user_store_card"
    end
  end
end
