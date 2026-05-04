module Passkit
  # Example eventTicket pass. Demonstrates the Apple-typed event semantics
  # (eventName, venueName, eventStartDate, performerNames, seats[]) that
  # are required for lock-screen surfacing, Smart Stack, and Siri prompts.
  # Host apps should subclass this pattern, not BasePass directly, when
  # building event passes.
  class UserTicket < BasePass
    EVENT_NAME = "Sample Event".freeze
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

    # iOS uses relevantDate to surface the pass on the lock screen around
    # showtime, independent of any geofence or beacon.
    def relevant_date
      event_start.iso8601
    end

    def expiration_date
      (event_start + 4.hours).iso8601
    end

    # Group multi-ticket purchases so they collapse into one stack in Wallet.
    def grouping_identifier
      return nil unless @generator.respond_to?(:user_id)
      "user-#{@generator.user_id}"
    end

    # Apple typed event semantics. Without these, the lock screen, Smart
    # Stack, and Siri ("you have a ticket coming up") integrations don't
    # fire — they key off these specific tags, not the field arrays.
    # @see https://developer.apple.com/documentation/walletpasses/semantictags
    def semantics
      {
        eventType: "PKEventTypeLivePerformance",
        eventName: EVENT_NAME,
        venueName: VENUE_NAME,
        venueLocation: {latitude: VENUE_LAT, longitude: VENUE_LON},
        eventStartDate: event_start.iso8601,
        eventEndDate: (event_start + 3.hours).iso8601,
        performerNames: ["Sample Performer"],
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

    private

    def event_start
      @event_start ||= Time.current.beginning_of_day + 7.days + 19.hours
    end

    def folder_name
      "user_store_card"
    end
  end
end
