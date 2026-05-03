# frozen_string_literal: true

require "rails_helper"

class TestRegistrationsController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def test_create
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1 = Passkit::Pass.first
    pass2 = Passkit::Pass.last

    assert_equal 2, Passkit::Pass.count

    register_pass(pass1)
    assert_equal 1, pass1.devices.count

    register_pass(pass2)
    assert_equal 1, pass2.devices.count
  end

  def test_create_when_device_already_registered_returns_200
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    register_pass(pass)
    assert_response :created

    register_pass(pass)
    assert_response :ok
    assert_equal 1, pass.devices.count
  end

  def test_create_two_passes_to_same_device
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1 = Passkit::Pass.first
    pass2 = Passkit::Pass.last

    register_pass(pass1)
    assert_response :created
    register_pass(pass2)
    assert_response :created

    assert_equal 1, Passkit::Device.count
    assert_equal 2, Passkit::Registration.count
  end

  def test_create_without_authorization_header_returns_401
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    post device_register_path(device_id: 1, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "1234567890"}.to_json

    assert_response :unauthorized
  end

  def test_create_with_wrong_authorization_token_returns_401
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    post device_register_path(device_id: 1, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "1234567890"}.to_json,
      headers: {"Authorization" => "ApplePass wrongtoken"}

    assert_response :unauthorized
  end

  def test_create_with_empty_body_succeeds_with_nil_push_token
    # Fixed in app/controllers/passkit/api/v1/registrations_controller.rb#push_token
    # — empty / non-JSON bodies no longer crash; push_token returns nil and the
    # device is registered without one.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    post device_register_path(device_id: 1, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: "",
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}

    assert_response :created
    assert_nil Passkit::Device.last.push_token
  end

  def test_show_returns_404_when_device_unknown
    get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: "nonexistent-device")
    assert_response :not_found
  end

  def test_show_returns_204_when_device_has_no_passes
    Passkit::Device.create!(identifier: "dev-1")
    get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: "dev-1")
    assert_response :no_content
  end

  def test_show_returns_200_with_lastUpdated_and_serialNumbers_when_passes_exist
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1 = Passkit::Pass.first
    pass2 = Passkit::Pass.last

    register_pass(pass1)
    register_pass(pass2)

    get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: 1)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_kind_of Hash, json
    assert json.key?("lastUpdated")
    assert_equal 2, json["serialNumbers"].size
  end

  # TODO(bug:app/controllers/passkit/api/v1/registrations_controller.rb:84): pins eager .all.filter — Phase C will use DB-level filter.
  def test_show_with_passesUpdatedSince_filter_loads_all_in_memory
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    passes = Passkit::Pass.order(:id).to_a

    passes.each { |p| register_pass(p) }

    # Set one pass's updated_at to 7 days ago, leaving 2 recent passes
    passes.first.update_columns(updated_at: 7.days.ago)
    recent_serials = passes[1..].map(&:serial_number)

    get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: 1),
      params: {passesUpdatedSince: Date.today.iso8601}

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal recent_serials.sort, json["serialNumbers"].sort
  end

  def test_destroy
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)
    destroy_registration(pass.registrations.first)
    assert_equal 0, pass.devices.count
    assert_equal 0, Passkit::Registration.count
    assert_equal 1, Passkit::Pass.count
    assert_equal 1, Passkit::Device.count
  end

  def test_destroy_without_auth_returns_401
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)
    registration = pass.registrations.first

    delete device_unregister_path(device_id: registration.device.id,
      pass_type_id: registration.pass.pass_type_identifier,
      serial_number: registration.pass.serial_number),
      params: {}.to_json

    assert_response :unauthorized
  end

  def test_destroy_is_idempotent
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)
    registration = pass.registrations.first

    destroy_registration(registration)
    assert_response :ok

    destroy_registration(registration)
    assert_response :ok

    assert_equal 0, Passkit::Registration.count
  end

  def test_destroy_matches_by_device_library_identifier
    # The {deviceLibraryIdentifier} URL segment is an opaque string per Apple's
    # spec; destroy must look up Device by `identifier`, not by AR primary key.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    identifier = "apple-device-#{SecureRandom.hex(8)}"

    post device_register_path(device_id: identifier, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "TOK"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal 1, Passkit::Registration.count

    delete device_unregister_path(device_id: identifier, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :ok
    assert_equal 0, Passkit::Registration.count
  end

  def test_destroy_with_unknown_device_identifier_is_a_noop_returning_200
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    delete device_unregister_path(device_id: "never-registered", pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :ok
  end

  def test_register_updates_push_token_when_device_already_exists
    # Apple rotates push tokens; subsequent registrations must update them.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1 = Passkit::Pass.first
    pass2 = Passkit::Pass.last
    identifier = "rotating-device"

    post device_register_path(device_id: identifier, pass_type_id: pass1.pass_type_identifier, serial_number: pass1.serial_number),
      params: {pushToken: "TOKEN-A"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass1.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal "TOKEN-A", Passkit::Device.find_by(identifier: identifier).push_token

    post device_register_path(device_id: identifier, pass_type_id: pass2.pass_type_identifier, serial_number: pass2.serial_number),
      params: {pushToken: "TOKEN-B"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass2.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal "TOKEN-B", Passkit::Device.find_by(identifier: identifier).push_token
    assert_equal 1, Passkit::Device.count
  end

  private

  def register_pass(pass)
    post device_register_path(device_id: 1, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "1234567890"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
  end

  def destroy_registration(registration)
    delete device_unregister_path(device_id: registration.device.id,
      pass_type_id: registration.pass.pass_type_identifier,
      serial_number: registration.pass.serial_number),
      params: {}.to_json,
      headers: {"Authorization" => "ApplePass #{registration.pass.authentication_token}"}
  end
end
