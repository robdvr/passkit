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

  # passesUpdatedSince filtering happens in SQL via
  # `passes.where("passkit_passes.updated_at >= ?", since)` —
  # see app/controllers/passkit/api/v1/registrations_controller.rb#fetch_registered_passes.
  def test_show_with_passesUpdatedSince_filter_returns_only_recent_passes
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

  # ------------------------------------------------------------------
  # passesUpdatedSince edge cases (production hardening)
  # ------------------------------------------------------------------

  def test_show_with_passesUpdatedSince_in_future_returns_204
    # Cutoff strictly after every pass's updated_at → empty result → 204.
    # Pin so a regression that returned 200 with [] (which iOS would treat
    # as the device having no passes) is caught immediately.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)

    get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: 1),
      params: {passesUpdatedSince: 1.year.from_now.iso8601}

    assert_response :no_content
  end

  def test_show_with_passesUpdatedSince_filters_at_sql_level_not_in_ruby
    # Runtime guard: count the SELECT against passkit_passes during the
    # request and assert it includes a WHERE on updated_at. Using a callback
    # on Active Support notifications keeps the test framework-agnostic
    # (no `assert_queries` helper required).
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    [Passkit::Pass.first, Passkit::Pass.last].each { |p| register_pass(p) }
    Passkit::Pass.first.update_columns(updated_at: 7.days.ago)

    captured_sql = []
    callback = ->(_name, _start, _finish, _id, payload) {
      captured_sql << payload[:sql] if payload[:sql].is_a?(String) && payload[:sql].include?("passkit_passes")
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get device_registrations_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], device_id: 1),
        params: {passesUpdatedSince: Date.today.iso8601}
    end

    assert_response :ok
    assert captured_sql.any? { |s| s.match?(/passkit_passes.*updated_at\s*>=/i) },
      "expected passesUpdatedSince to push the >= filter into SQL; SQL seen:\n#{captured_sql.inspect}"
  end

  # ------------------------------------------------------------------
  # Push token edge cases
  # ------------------------------------------------------------------

  def test_register_with_explicit_null_push_token_in_json_body_succeeds
    # Apple sometimes posts {"pushToken": null} during APNs token rotation
    # gaps. The controller must register the device without overwriting
    # any prior token to nil and without 5xx-ing.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    post device_register_path(device_id: "rotating-null", pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: nil}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "Content-Type" => "application/json"}

    assert_response :created
    assert_nil Passkit::Device.find_by(identifier: "rotating-null").push_token
  end

  def test_register_does_not_overwrite_existing_push_token_when_subsequent_body_has_blank_token
    # Existing behavior: `device.update!(push_token: token) if token.present? && device.push_token != token`.
    # A subsequent registration with blank token must not zero out the
    # previously-stored APNs token. iOS sometimes posts blank during
    # transient network errors.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1, pass2 = Passkit::Pass.order(:id).to_a
    identifier = "preserve-token-device"

    post device_register_path(device_id: identifier, pass_type_id: pass1.pass_type_identifier, serial_number: pass1.serial_number),
      params: {pushToken: "ORIGINAL"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass1.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal "ORIGINAL", Passkit::Device.find_by(identifier: identifier).push_token

    post device_register_path(device_id: identifier, pass_type_id: pass2.pass_type_identifier, serial_number: pass2.serial_number),
      params: {pushToken: ""}.to_json,
      headers: {"Authorization" => "ApplePass #{pass2.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal "ORIGINAL", Passkit::Device.find_by(identifier: identifier).push_token,
      "blank pushToken must not overwrite a previously-stored value"
  end

  # ------------------------------------------------------------------
  # destroy isolation
  # ------------------------------------------------------------------

  def test_destroy_unregisters_only_target_device_pass_pair
    # Two distinct devices each registered to the same pass; destroying
    # one's registration must leave the other intact. Pin against an
    # accidental `delete_all` that drops by serial alone.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first

    post device_register_path(device_id: "dev-keep", pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "TKEEP"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    post device_register_path(device_id: "dev-drop", pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: "TDROP"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal 2, Passkit::Registration.count

    delete device_unregister_path(device_id: "dev-drop", pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :ok

    surviving = Passkit::Registration.includes(:device).map { |r| r.device.identifier }
    assert_equal ["dev-keep"], surviving
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
