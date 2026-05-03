# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"

class TestFactory < ActiveSupport::TestCase
  def test_create_pass_creates_passkit_pass_record
    Passkit::Pass.delete_all
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_equal 1, Passkit::Pass.count
    assert_equal "Passkit::ExampleStoreCard", Passkit::Pass.last.klass
  end

  def test_create_pass_returns_path_to_pkpass_file
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert path.to_s.end_with?(".pkpass"),
      "Expected returned path to end with .pkpass, got: #{path}"
    assert File.exist?(path), "Expected pkpass file to exist at #{path}"
  end

  def test_create_pass_with_nil_generator
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    assert_nil pass.generator_id
    assert_nil pass.generator_type
  end

  def test_create_pass_with_active_record_generator
    user = User.find(1)
    Passkit::Factory.create_pass(Passkit::UserStoreCard, user)
    pass = Passkit::Pass.last
    assert_equal user, pass.generator
  end

  def test_create_pass_with_class_argument_coerces_to_string_for_klass_column
    # ActiveRecord coerces the class to a string via to_s when persisting to a
    # string column. Pin this current behavior.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_equal "Passkit::ExampleStoreCard", Passkit::Pass.last.klass
  end

  def test_create_pass_assigns_serial_number_and_authentication_token
    # TODO(bug:app/models/passkit/pass.rb:50): TOCTOU - pinning current loop behavior.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    refute_nil pass.serial_number
    refute_nil pass.authentication_token
  end

  def test_create_pass_assigns_unique_serial_via_db_index
    # The before_validation no longer pre-checks via Passkit::Pass.exists?; the
    # DB unique index is the source of truth.
    Passkit::Pass.expects(:exists?).never
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_equal 2, Passkit::Pass.count
    assert_equal 2, Passkit::Pass.distinct.count(:serial_number)
  end
end
