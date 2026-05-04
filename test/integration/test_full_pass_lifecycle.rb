# frozen_string_literal: true

require "rails_helper"
require_relative "../support/pkpass_helpers"

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

  # End-to-end Android-flavored lifecycle. The same signed URL is served to
  # iOS and Android (UrlGenerator#android == #ios), but the controller's
  # response divergence kicks in via the User-Agent: Apple Wallet UAs receive
  # `.pkpasses` bundles, while Android browsers receive an HTML index that
  # links to per-pass `.pkpass` downloads. This test pins the entire Android
  # path including signature verification of the final downloaded pass.
  def test_android_browser_lifecycle_html_index_then_per_pass_download
    user = User.find(1)
    assert_equal 2, user.tickets.count, "fixtures must provide a multi-ticket user for this test"

    # 1) Android-equivalent URL is identical to iOS URL.
    gen = Passkit::UrlGenerator.new(Passkit::UserTicket, user, :tickets)
    assert_equal gen.ios, gen.android,
      "UrlGenerator#android must alias #ios — both platforms share one signed URL"

    # 2) Extract the encrypted payload from the URL and request it with a
    #    Chrome-on-Android UA. Use the path helper rather than the full URL
    #    so the integration test stays in-process.
    payload = gen.android.split("/").last
    refute_empty payload

    chrome_android_ua = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 " \
                       "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    get passes_api_path(payload), headers: {"User-Agent" => chrome_android_ua}

    # 3) HTML index, not a `.pkpasses` bundle (Android can't open those).
    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
    assert_match(/Your passes \(2\)/, response.body)

    # 4) No pass rows are persisted yet — generation is deferred until click.
    assert_equal 0, Passkit::Pass.count

    # 5) Parse the first per-pass href and follow it. URLs are HTML-escaped
    #    in the index template, so unescape ampersands before re-using.
    href_match = response.body.match(/href="([^"]+)"/)
    refute_nil href_match, "expected at least one per-pass <a href>"
    per_pass_path = href_match[1].gsub("&amp;", "&")
    per_pass_payload = per_pass_path.split("/").last
    refute_empty per_pass_payload
    refute_equal payload, per_pass_payload,
      "per-pass payload must be re-encrypted with collection_name nil"

    get passes_api_path(per_pass_payload), headers: {"User-Agent" => chrome_android_ua}

    # 6) Single signed `.pkpass` returned with the correct MIME type. The
    #    same MIME is what triggers PassWallet / Google Wallet on Android.
    assert_response :success
    assert_equal "application/vnd.apple.pkpass", response.headers["Content-Type"].split(";").first

    # 7) The `.pkpass` is structurally + cryptographically valid. Signature
    #    verifies against the test CA, manifest hashes match every entry,
    #    pass.json passes Apple's schema for eventTicket and the iOS 18+
    #    enhanced poster-style key shapes.
    pkpass = PkpassHelpers.read_pkpass(response.body)
    PkpassHelpers::REQUIRED_PKPASS_ENTRIES.each { |req| assert_includes pkpass[:entry_names], req }
    assert pkpass[:entry_names].any? { |n| n == "icon.png" }
    assert PkpassHelpers.verify_pkpass_signature!(pkpass)
    assert PkpassHelpers.assert_valid_pass_json(pkpass[:pass_json], pass_type: :eventTicket, enhanced_event_ticket: true)

    # 8) Localized `pass.strings` files are present in the manifest with
    #    matching SHA1 hashes (lifecycle includes the localization helper).
    %w[en.lproj/pass.strings es.lproj/pass.strings].each do |path|
      assert_includes pkpass[:entry_names], path, "expected #{path} in .pkpass entries"
      expected = Digest::SHA1.hexdigest(pkpass[:entry_bytes][path])
      assert_equal expected, pkpass[:manifest][path],
        "manifest hash for #{path} must equal SHA1 of the file bytes"
    end

    # 9) A Pass row was persisted exactly once for this click.
    assert_equal 1, Passkit::Pass.count
  end
end
