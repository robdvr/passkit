# frozen_string_literal: true

require "rails_helper"

class TestFullPassLifecycle < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def test_complete_pass_lifecycle
    # 1) URL generation: build an encrypted pass URL.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard)

    # 2) Download: GET /passes/:payload — Apple-style pass creation.
    get passes_api_path(payload)
    assert_response :success
    assert_equal "application/vnd.apple.pkpass", response.headers["Content-Type"].split(";").first
    pkpass = Zip::File.open_buffer(StringIO.new(response.body))
    assert_includes pkpass.entries.map(&:name), "pass.json"
    assert_includes pkpass.entries.map(&:name), "manifest.json"
    assert_includes pkpass.entries.map(&:name), "signature"

    # 3) Verify pass record exists with serial+token.
    assert_equal 1, Passkit::Pass.count
    pass = Passkit::Pass.last
    assert_match(/\A[0-9a-f-]{36}\z/, pass.serial_number)
    refute_nil pass.authentication_token

    # 4) Register: POST registrations endpoint with device_id and pushToken.
    post device_register_path(
      device_id: "test-device-1",
      pass_type_id: pass.pass_type_identifier,
      serial_number: pass.serial_number
    ), params: {pushToken: "TEST-PUSH-TOKEN"}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "Content-Type" => "application/json"}
    assert_response :created
    assert_equal 1, Passkit::Device.count
    assert_equal "TEST-PUSH-TOKEN", Passkit::Device.last.push_token
    assert_equal 1, Passkit::Registration.count

    # 5) Show pass with auth → returns the .pkpass binary.
    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :success
    refute_empty response.body
    assert_match(/\A\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT\z/, response.headers["Last-Modified"])

    # 6) Show with If-Modified-Since in the future → 304.
    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "If-Modified-Since" => 1.hour.from_now.httpdate}
    assert_response :not_modified
    assert_equal "", response.body

    # 7) Registrations index for the device → returns serials.
    # All registration endpoints route on `deviceLibraryIdentifier` per the
    # Apple PassKit spec, so `device_id` is the identifier string.
    device_identifier = Passkit::Device.last.identifier
    get device_registrations_path(device_id: device_identifier, pass_type_id: pass.pass_type_identifier)
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [pass.serial_number], json["serialNumbers"]

    # 8) Unregister with the same identifier.
    delete device_unregister_path(
      device_id: device_identifier,
      pass_type_id: pass.pass_type_identifier,
      serial_number: pass.serial_number
    ), headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :ok
    assert_equal 0, Passkit::Registration.count

    # 9) After unregister, registrations index returns 204.
    get device_registrations_path(device_id: device_identifier, pass_type_id: pass.pass_type_identifier)
    assert_response :no_content
  end
end
