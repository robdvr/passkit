# frozen_string_literal: true

require "rails_helper"

class TestExampleStoreCard < ActiveSupport::TestCase
  ISO8601_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/

  def setup
    @subject = Passkit::ExampleStoreCard.new
  end

  def test_inherits_from_base_pass
    assert Passkit::ExampleStoreCard < Passkit::BasePass
  end

  def test_pass_type_is_storeCard
    assert_equal :storeCard, @subject.pass_type
  end

  def test_logo_text_is_loyalty_card
    assert_equal "Loyalty Card", @subject.logo_text
  end

  def test_organization_name
    assert_equal "Passkit", @subject.organization_name
  end

  def test_barcodes_includes_qr_format
    barcodes = @subject.barcodes
    assert_kind_of Array, barcodes
    refute_empty barcodes
    assert_equal "PKBarcodeFormatQR", barcodes.first[:format]
  end

  def test_semantics_has_balance
    assert_equal({balance: {amount: "100", currencyCode: "USD"}}, @subject.semantics)
  end

  def test_header_fields_includes_balance_field
    assert_equal(
      [{key: "balance", label: "Balance", value: 100, currencyCode: "$"}],
      @subject.header_fields
    )
  end

  def test_back_fields_count_is_3
    back_fields = @subject.back_fields
    assert_equal 3, back_fields.count
    assert_equal %w[example1 example2 example3], back_fields.map { |f| f[:key] }
  end

  def test_auxiliary_fields_count_is_3
    auxiliary_fields = @subject.auxiliary_fields
    assert_equal 3, auxiliary_fields.count
    assert_equal %w[name email phone], auxiliary_fields.map { |f| f[:key] }
  end

  def test_relevant_date_is_iso8601_string
    assert_match ISO8601_REGEX, @subject.relevant_date
  end

  def test_expiration_date_is_iso8601_string
    expiration = @subject.expiration_date
    assert_match ISO8601_REGEX, expiration
    parsed = Time.parse(expiration)
    delta = parsed - Time.current
    # Expect ~24h from now (allow generous slop for clock drift / test runtime).
    assert_in_delta 24 * 60 * 60, delta, 60
  end

  def test_smoke_test_generate_via_factory
    path = nil
    assert_nothing_raised do
      path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    end
    assert path.to_s.end_with?(".pkpass"),
      "Expected returned path to end with .pkpass, got: #{path}"
    assert File.exist?(path), "Expected pkpass file to exist at #{path}"
    assert File.size(path) > 0, "Expected pkpass file to be non-zero size"
  end
end
