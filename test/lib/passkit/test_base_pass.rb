# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"

class TestBasePass < ActiveSupport::TestCase
  def setup
    @subject = Passkit::BasePass.new
  end

  # Captures original ENV values, applies overrides, yields, then restores.
  def with_env(overrides)
    saved = {}
    overrides.each_key { |k| saved[k] = ENV[k] }
    begin
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  # ---- DEFAULTS ----

  def test_format_version_default
    if ENV["PASSKIT_FORMAT_VERSION"]
      assert_equal ENV["PASSKIT_FORMAT_VERSION"], @subject.format_version
    else
      assert_equal 1, @subject.format_version
    end
  end

  def test_format_version_uses_env_and_coerces_to_integer
    with_env("PASSKIT_FORMAT_VERSION" => "2") do
      assert_equal 2, Passkit::BasePass.new.format_version
    end
  end

  def test_apple_team_identifier_uses_env
    assert_equal ENV["PASSKIT_APPLE_TEAM_IDENTIFIER"], @subject.apple_team_identifier
  end

  def test_apple_team_identifier_raises_when_env_unset
    with_env("PASSKIT_APPLE_TEAM_IDENTIFIER" => nil) do
      error = assert_raises(Passkit::Error) { Passkit::BasePass.new.apple_team_identifier }
      assert_match(/PASSKIT_APPLE_TEAM_IDENTIFIER/, error.message)
    end
  end

  def test_pass_type_identifier_uses_env
    assert_equal ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], @subject.pass_type_identifier
  end

  def test_pass_type_identifier_raises_when_env_unset
    with_env("PASSKIT_PASS_TYPE_IDENTIFIER" => nil) do
      error = assert_raises(Passkit::Error) { Passkit::BasePass.new.pass_type_identifier }
      assert_match(/PASSKIT_PASS_TYPE_IDENTIFIER/, error.message)
    end
  end

  def test_web_service_url_uses_env
    assert_equal "#{ENV["PASSKIT_WEB_SERVICE_HOST"]}/passkit/api", @subject.web_service_url
  end

  def test_web_service_url_raises_when_env_unset
    with_env("PASSKIT_WEB_SERVICE_HOST" => nil) do
      error = assert_raises(Passkit::Error) { Passkit::BasePass.new.web_service_url }
      assert_match(/PASSKIT_WEB_SERVICE_HOST/, error.message)
    end
  end

  def test_language_default_nil
    assert_nil @subject.language
  end

  def test_pass_type_default_storeCard
    assert_equal :storeCard, @subject.pass_type
  end

  def test_voided_default_false
    assert_equal false, @subject.voided
  end

  def test_sharing_prohibited_default_false
    assert_equal false, @subject.sharing_prohibited
  end

  def test_suppress_strip_shine_default_true
    assert_equal true, @subject.suppress_strip_shine
  end

  def test_organization_name_default
    assert_equal "Passkit", @subject.organization_name
  end

  def test_description_default
    assert_equal "A basic description for a pass", @subject.description
  end

  def test_foreground_color_default
    assert_equal "rgb(0, 0, 0)", @subject.foreground_color
  end

  def test_background_color_default
    assert_equal "rgb(255, 255, 255)", @subject.background_color
  end

  def test_label_color_default
    assert_equal "rgb(0, 0, 0)", @subject.label_color
  end

  def test_logo_text_default
    assert_equal "Logo text", @subject.logo_text
  end

  def test_locations_default_empty_array
    assert_equal [], @subject.locations
  end

  def test_associated_store_identifiers_default_empty
    assert_equal [], @subject.associated_store_identifiers
  end

  def test_beacons_default_empty
    assert_equal [], @subject.beacons
  end

  def test_header_fields_default_empty
    assert_equal [], @subject.header_fields
  end

  def test_primary_fields_default_empty
    assert_equal [], @subject.primary_fields
  end

  def test_secondary_fields_default_empty
    assert_equal [], @subject.secondary_fields
  end

  def test_auxiliary_fields_default_empty
    assert_equal [], @subject.auxiliary_fields
  end

  def test_back_fields_default_empty
    assert_equal [], @subject.back_fields
  end

  def test_barcodes_default_empty
    assert_equal [], @subject.barcodes
  end

  def test_barcode_default_qr
    expected = {
      messageEncoding: "iso-8859-1",
      format: "PKBarcodeFormatQR",
      message: "https://github.com/coorasse/passkit",
      altText: "https://github.com/coorasse/passkit"
    }
    assert_equal expected, @subject.barcode
  end

  def test_max_distance_default_nil
    assert_nil @subject.max_distance
  end

  def test_app_launch_url_default_nil
    assert_nil @subject.app_launch_url
  end

  def test_expiration_date_default_nil
    assert_nil @subject.expiration_date
  end

  def test_grouping_identifier_default_nil
    assert_nil @subject.grouping_identifier
  end

  def test_nfc_default_nil
    assert_nil @subject.nfc
  end

  def test_relevant_date_default_nil
    assert_nil @subject.relevant_date
  end

  def test_semantics_default_nil
    assert_nil @subject.semantics
  end

  def test_user_info_default_nil
    assert_nil @subject.user_info
  end

  def test_boarding_pass_default_empty_hash
    assert_equal({}, @subject.boarding_pass)
  end

  def test_add_other_files_default_is_noop
    assert_nil @subject.add_other_files("/tmp/whatever")
  end

  # ---- LAST_UPDATE / GENERATOR ----

  def test_last_update_with_no_generator_returns_nil
    assert_nil Passkit::BasePass.new.last_update
  end

  def test_last_update_with_generator_returns_generator_updated_at
    now = Time.now
    generator = stub(updated_at: now)
    pass = Passkit::BasePass.new(generator)
    assert_equal now, pass.last_update
  end

  # ---- PASS_PATH ----

  def test_pass_path_returns_rails_private_dir_when_present
    pass = Passkit::ExampleStoreCard.new
    # No private dir for example_store_card in dummy app, so it falls back to gem internal.
    refute_equal Rails.root.join("private/passkit/example_store_card").to_s,
      pass.pass_path.to_s

    rails_dir = Rails.root.join("private/passkit/example_store_card")
    FileUtils.mkdir_p(rails_dir)
    File.write(rails_dir.join(".keep"), "")
    @created_rails_dir = rails_dir
    assert_equal rails_dir.to_s, pass.pass_path.to_s
  end

  def test_pass_path_falls_back_to_gem_internal_when_rails_dir_absent
    pass = Passkit::ExampleStoreCard.new
    # Ensure no leftover rails private dir for example_store_card.
    rails_dir = Rails.root.join("private/passkit/example_store_card")
    FileUtils.rm_rf(rails_dir) if File.directory?(rails_dir)
    assert pass.pass_path.to_s.end_with?("lib/passkit/example_store_card"),
      "Expected pass_path to end with 'lib/passkit/example_store_card', got: #{pass.pass_path}"
  end

  def test_pass_path_for_user_store_card_uses_dummy_private
    pass = Passkit::UserStoreCard.new
    assert pass.pass_path.to_s.end_with?("test/dummy/private/passkit/user_store_card"),
      "Expected pass_path to end with 'test/dummy/private/passkit/user_store_card', got: #{pass.pass_path}"
  end

  def test_folder_name_derives_from_class_demodulized_underscored
    klass = Class.new(Passkit::BasePass)
    Passkit.const_set(:FooBar, klass) unless Passkit.const_defined?(:FooBar)
    instance = Passkit.const_get(:FooBar).new
    assert_equal "foo_bar", instance.send(:folder_name)
  ensure
    Passkit.send(:remove_const, :FooBar) if Passkit.const_defined?(:FooBar)
  end

  # ---- FILE_NAME ----

  def test_file_name_is_memoized_uuid
    pass = Passkit::BasePass.new
    first = pass.file_name
    second = pass.file_name
    assert_equal first, second
    assert_match(/\A[0-9a-f-]{36}\z/, first)
  end

  # ---- iOS 18+ ENHANCED EVENT TICKET DEFAULTS ----

  def test_preferred_style_schemes_default_nil
    assert_nil @subject.preferred_style_schemes
  end

  def test_additional_info_fields_default_empty_array
    assert_equal [], @subject.additional_info_fields
  end

  def test_event_logo_text_default_nil
    assert_nil @subject.event_logo_text
  end

  def test_relevant_dates_default_empty_array
    assert_equal [], @subject.relevant_dates
  end

  def test_use_automatic_colors_default_nil
    assert_nil @subject.use_automatic_colors
  end

  def test_footer_background_color_default_nil
    assert_nil @subject.footer_background_color
  end

  def test_auxiliary_store_identifiers_default_empty_array
    assert_equal [], @subject.auxiliary_store_identifiers
  end

  %i[
    bag_policy_url parking_information_url merchandise_url order_food_url
    transit_information_url directions_information_url transfer_url add_on_url
    accessibility_url purchase_parking_url sell_url
    contact_venue_email contact_venue_phone_number contact_venue_website
  ].each do |method|
    define_method("test_#{method}_default_nil") do
      assert_nil @subject.public_send(method),
        "expected BasePass##{method} to default to nil so subclasses opt in"
    end
  end

  # ---- LOCALIZATION DEFAULT ----

  def test_localized_strings_default_empty_hash
    assert_equal({}, @subject.localized_strings)
  end

  def teardown
    if @created_rails_dir && File.directory?(@created_rails_dir)
      FileUtils.rm_rf(@created_rails_dir)
    end
  end
end
