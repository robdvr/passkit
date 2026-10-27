module Passkit
  # Example iOS 27 Poster Generic pass with featured actions. Wallet on iOS 27
  # renders `poster_generic`; iOS 26 and earlier render the `generic` fields,
  # so both carry the same content.
  class UserMembershipCard < BasePass
    def pass_type
      :generic
    end

    def organization_name
      "Passkit"
    end

    def description
      "Membership card for #{member_name}"
    end

    def logo_text
      "Passkit Club"
    end

    def barcodes
      [{messageEncoding: "iso-8859-1", format: "PKBarcodeFormatQR", message: "member-#{@generator&.id}", altText: member_number}]
    end

    def header_fields
      [{key: "member_number", label: "Member No.", value: member_number}]
    end

    def primary_fields
      [{key: "member_name", label: "Name", value: member_name}]
    end

    def secondary_fields
      [{key: "tier", label: "Tier", value: "Gold"}]
    end

    def back_fields
      [{key: "terms", label: "Terms", value: "Valid for one year from the date of issue."}]
    end

    def poster_generic
      {
        headerFields: header_fields,
        primaryFields: primary_fields,
        footerFields: [{key: "tier", value: "Gold"}],
        backFields: back_fields
      }
    end

    def featured_actions
      [
        {identifier: "benefits", type: "membershipBenefits", url: "https://example.com/benefits"},
        {identifier: "visit", type: "place", placeIdentifier: "I63802885C8189B2B"}
      ]
    end

    private

    def member_name
      @generator&.name.to_s
    end

    def member_number
      "M-#{@generator&.id.to_s.rjust(6, "0")}"
    end

    def folder_name
      "user_store_card"
    end
  end
end
