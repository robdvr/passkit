# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"

class TestPasskitPass < ActiveSupport::TestCase
  DELEGATED_METHODS = [
    :apple_team_identifier,
    :app_launch_url,
    :associated_store_identifiers,
    :auxiliary_fields,
    :back_fields,
    :background_color,
    :barcode,
    :barcodes,
    :beacons,
    :boarding_pass,
    :description,
    :expiration_date,
    :file_name,
    :foreground_color,
    :format_version,
    :grouping_identifier,
    :header_fields,
    :label_color,
    :language,
    :locations,
    :logo_text,
    :max_distance,
    :nfc,
    :organization_name,
    :pass_path,
    :pass_type,
    :pass_type_identifier,
    :primary_fields,
    :relevant_date,
    :secondary_fields,
    :semantics,
    :sharing_prohibited,
    :suppress_strip_shine,
    :user_info,
    :voided,
    :web_service_url
  ].freeze

  # ---- VALIDATION & CALLBACKS ----

  def test_serial_number_set_in_before_validation
    p = Passkit::Pass.new(klass: "Passkit::ExampleStoreCard")
    p.valid?
    assert_match(/\A[0-9a-f-]{36}\z/, p.serial_number)
  end

  def test_authentication_token_set_in_before_validation
    p = Passkit::Pass.new(klass: "Passkit::ExampleStoreCard")
    p.valid?
    assert p.authentication_token.is_a?(String)
    assert_match(/\A[0-9a-f]+\z/, p.authentication_token)
  end

  def test_klass_presence_required
    p = Passkit::Pass.new
    refute p.valid?
    assert_includes p.errors.attribute_names, :klass
  end

  def test_serial_number_uniqueness
    first = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    # The before_validation callback regenerates serial_number on create; force
    # it to produce the same UUID as `first` so we exercise the uniqueness
    # validator (and also stub exists? so the loop terminates).
    SecureRandom.stubs(:uuid).returns(first.serial_number)
    Passkit::Pass.stubs(:exists?).returns(false)
    duplicate = Passkit::Pass.new(klass: "Passkit::ExampleStoreCard")
    refute duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :serial_number
  ensure
    SecureRandom.unstub(:uuid)
    Passkit::Pass.unstub(:exists?)
  end

  def test_belongs_to_generator_polymorphic_optional
    no_gen = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    assert_nil no_gen.generator
    assert_nil no_gen.generator_type
    assert_nil no_gen.generator_id

    user = User.find(1)
    with_gen = Passkit::Pass.create!(klass: "Passkit::UserStoreCard", generator: user)
    assert_equal "User", with_gen.generator_type
    assert_equal 1, with_gen.generator_id
    assert_equal user, with_gen.generator
  end

  # ---- INSTANCE & DELEGATION ----

  def test_instance_returns_klass_constantized_with_generator
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    assert_kind_of Passkit::ExampleStoreCard, p.instance
  end

  def test_instance_is_memoized
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    first = p.instance
    second = p.instance
    assert first.equal?(second), "Expected p.instance to be memoized (same object)"
  end

  def test_instance_passes_generator_to_constructor
    user = User.find(1)
    p = Passkit::Pass.create!(klass: "Passkit::UserStoreCard", generator: user)
    assert_equal user, p.instance.instance_variable_get(:@generator)
  end

  def test_delegated_methods_forward_to_instance
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    DELEGATED_METHODS.each do |m|
      sentinel = Object.new
      p.instance.stubs(m).returns(sentinel)
      assert_equal sentinel, p.public_send(m), "Expected ##{m} to delegate to instance"
      p.instance.unstub(m)
    end
  end

  # ---- LAST_UPDATE ----

  def test_last_update_returns_instance_value_when_set
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    known_time = Time.utc(2024, 1, 2, 3, 4, 5)
    p.instance.stubs(:last_update).returns(known_time)
    assert_equal known_time, p.last_update
  end

  def test_last_update_falls_back_to_updated_at_when_instance_returns_nil
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    p.instance.stubs(:last_update).returns(nil)
    assert_equal p.updated_at, p.last_update
  end

  # ---- SERIAL NUMBER GENERATION ----

  def test_serial_number_generation_no_longer_polls_exists
    # The before_validation no longer loops calling Passkit::Pass.exists?; the DB
    # unique index on serial_number is the authoritative collision check.
    Passkit::Pass.expects(:exists?).never
    p = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    assert p.persisted?
    assert_match(/\A[0-9a-f-]{36}\z/, p.serial_number)
  end

  def test_duplicate_serial_number_violates_db_unique_index
    first = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    # Bypass validations to confirm the DB constraint is in place.
    duplicate = Passkit::Pass.new(klass: "Passkit::ExampleStoreCard")
    duplicate.serial_number = first.serial_number
    duplicate.authentication_token = SecureRandom.hex
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save(validate: false) }
  end
end
