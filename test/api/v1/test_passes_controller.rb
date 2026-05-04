# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/pkpass_helpers"

class TestPassesController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def test_create
    payload = Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard)
    get passes_api_path(payload)
    assert_equal 1, Passkit::Pass.count
    assert_response :success
    zip_file = Zip::File.open_buffer(StringIO.new(response.body))
    assert_equal 7, zip_file.size
  end

  def test_create_collection_serves_pkpasses_bundle_to_apple_wallet
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "PassKit/1.0 CFNetwork/1410 Darwin/22.0.0"}
    assert_response :success
    assert_equal "application/vnd.apple.pkpasses", response.headers["Content-Type"].split(";").first
    assert_equal 2, Passkit::Pass.count
    unzipped_passes = Zip::File.open_buffer(StringIO.new(response.body))
    assert_equal 2, unzipped_passes.size # the main zip file contains two passes
    unzipped_passes.each do |entry|
      assert_includes entry.name, ".pkpass"
      inner_zip = Zip::File.open_buffer(StringIO.new(entry.get_input_stream.read))
      assert_includes inner_zip.entries.map(&:name), "pass.json"
    end
  end

  def test_create_collection_serves_html_index_to_non_wallet_clients
    # Android browsers / desktop browsers / third-party readers cannot open
    # .pkpasses bundles. The controller must serve a per-pass HTML index so
    # the user can install each pass individually.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14)"}

    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
    # No .pkpass rows are created until the user clicks an individual link.
    assert_equal 0, Passkit::Pass.count

    body = response.body
    assert_match(/Your passes \(2\)/, body)
    # One link per ticket in the user's collection.
    assert_equal 2, body.scan("<a href=").length
    # Each link points back at this same controller's per-pass route.
    # The engine is mounted at /passkit in the dummy app, so the path is
    # /passkit/api/v1/passes/<encrypted-payload>.
    assert_match(%r{href="[^"]*/api/v1/passes/[A-F0-9]+"}, body)
  end

  def test_create_collection_with_empty_relation_returns_html_with_zero_items
    empty_user = User.create!(name: "user without tickets")
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, empty_user, :tickets)

    get passes_api_path(payload), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14)"}

    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
    assert_equal 0, Passkit::Pass.count
    assert_match(/Your passes \(0\)/, response.body)
    assert_equal 0, response.body.scan("<a href=").length
  end

  # Apple's UAs are `PassKit/<ver>` and `Wallet/<ver>`. Third-party app names
  # that contain "Wallet" as a standalone word (e.g. "Google Wallet/2.0",
  # "My Wallet App/1.0") must NOT be classified as Apple Wallet, otherwise
  # they get a `.pkpasses` bundle they cannot open.
  def test_create_collection_does_not_classify_google_wallet_as_apple_wallet
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "Google Wallet/2.0"}
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
  end

  def test_create_collection_does_not_classify_my_wallet_app_as_apple_wallet
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "My Wallet App 1.0"}
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
  end

  # DX warning: when `pass_generators` allowlist is non-empty and a per-item
  # link's generator_class is not in it, the click would silently 404. Logging
  # at link-generation time surfaces the mismatch in dev.
  def test_create_collection_html_warns_when_item_class_not_in_pass_generators_allowlist
    # Allow the outer "User" so the request itself isn't 404'd at decrypt time,
    # but omit "Ticket" so each per-item link triggers the warning.
    Passkit.configuration.pass_generators = ["User"]
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)

    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(captured)

    get passes_api_path(payload), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14)"}
    assert_response :success
    assert_match(/\[Passkit\] bundle_index_link: Ticket is not in/, captured.string)
  ensure
    Rails.logger = original_logger
    Passkit.configuration.pass_generators = []
  end

  def test_create_collection_html_does_not_warn_when_pass_generators_allowlist_is_empty
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)

    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(captured)

    get passes_api_path(payload), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14)"}
    assert_response :success
    refute_match(/bundle_index_link/, captured.string)
  ensure
    Rails.logger = original_logger
  end

  def test_show
    _pkpass = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_equal 1, Passkit::Pass.count
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number)
    assert_response :unauthorized

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}

    assert_response :success

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}", "If-Modified-Since" => Time.zone.now.httpdate}

    assert_equal "", response.body
    assert_equal pass.last_update.httpdate, response.headers["Last-Modified"]
    assert_response :not_modified
  end

  def test_create_with_expired_payload_returns_404
    payload = encrypted_payload(Passkit::ExampleStoreCard, valid_until: 31.days.ago)
    get passes_api_path(payload)
    assert_response :not_found
  end

  def test_create_with_nil_valid_until_returns_404
    payload = Passkit::UrlEncrypt.encrypt(
      valid_until: nil,
      generator_class: nil,
      generator_id: nil,
      pass_class: Passkit::ExampleStoreCard.name,
      collection_name: nil
    )
    get passes_api_path(payload)
    assert_response :not_found
  end

  def test_create_with_malformed_valid_until_returns_404
    payload = Passkit::UrlEncrypt.encrypt(
      valid_until: "not-a-real-date",
      generator_class: nil,
      generator_id: nil,
      pass_class: Passkit::ExampleStoreCard.name,
      collection_name: nil
    )
    get passes_api_path(payload)
    assert_response :not_found
  end

  def test_create_with_payload_referencing_missing_generator_returns_404
    payload = Passkit::UrlEncrypt.encrypt(
      valid_until: 30.days.from_now,
      generator_class: "User",
      generator_id: 999_999,
      pass_class: Passkit::UserTicket.name,
      collection_name: nil
    )
    # `set_generator` resolves the polymorphic record with `find_by` + explicit
    # `head :not_found`, so this 404 is self-contained and does not rely on
    # Rails' show_exceptions middleware to translate RecordNotFound.
    get passes_api_path(payload)
    assert_response :not_found
  end

  def test_create_with_malformed_encrypted_payload_returns_404
    # `decrypt_payload` rescues OpenSSL::Cipher::CipherError so tampered or
    # malformed URLs cannot be probed for crypto errors via the response.
    get passes_api_path("DEADBEEF")
    assert_response :not_found
  end

  def test_create_with_tampered_ciphertext_returns_404
    payload = encrypted_payload(Passkit::ExampleStoreCard)
    tampered = payload.dup
    # Flip a byte in the ciphertext portion (past version+IV+tag).
    offset = Passkit::UrlEncrypt::VERSION_BYTE.length +
      Passkit::UrlEncrypt::IV_HEX_LEN +
      Passkit::UrlEncrypt::AUTH_TAG_HEX_LEN
    tampered[offset] = ((tampered[offset] == "0") ? "1" : "0")

    get passes_api_path(tampered)
    assert_response :not_found
  end

  def test_create_with_collection_name_returning_empty_relation_produces_empty_pkpasses_zip
    # Build a User with no associated tickets so the `tickets` collection is empty.
    empty_user = User.create!(name: "user without tickets")
    assert_equal 0, empty_user.tickets.count

    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, empty_user, :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "PassKit/1.0 CFNetwork/1410 Darwin/22.0.0"}

    # Current behavior: the controller iterates the (empty) collection, creates zero passes,
    # then compresses an empty list of files into an outer .pkpasses zip. The response
    # succeeds with a zip that has zero entries inside it.
    assert_response :success
    assert_equal 0, Passkit::Pass.count
    outer_zip = Zip::File.open_buffer(StringIO.new(response.body))
    assert_equal 0, outer_zip.size
  end

  def test_show_with_unknown_serial_number_returns_unauthorized
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: "bogus-serial-#{SecureRandom.hex(4)}"),
      headers: {"Authorization" => "ApplePass #{SecureRandom.hex}"}
    assert_response :unauthorized
  end

  def test_show_with_correct_serial_but_wrong_token_returns_unauthorized
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass wrongtoken"}
    assert_response :unauthorized
  end

  def test_show_with_correct_token_but_wrong_serial_returns_unauthorized
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: "wrong-serial"),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :unauthorized
  end

  def test_show_returns_RFC2616_last_modified_header
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :success
    assert_match(/\A\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT\z/, response.headers["Last-Modified"])
  end

  def test_show_with_malformed_if_modified_since_treats_as_not_present
    # A garbage If-Modified-Since header must not 500 the show action.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "If-Modified-Since" => "not-a-real-date"}
    assert_response :success
  end

  def test_create_rejects_pass_class_outside_allowlist_when_set
    Passkit.configuration.pass_classes = ["Passkit::OnlyThisOne"]
    payload = encrypted_payload(Passkit::ExampleStoreCard)
    get passes_api_path(payload)
    assert_response :not_found
  ensure
    Passkit.configuration.pass_classes = []
  end

  def test_create_accepts_pass_class_in_allowlist
    Passkit.configuration.pass_classes = ["Passkit::ExampleStoreCard"]
    payload = encrypted_payload(Passkit::ExampleStoreCard)
    get passes_api_path(payload)
    assert_response :success
  ensure
    Passkit.configuration.pass_classes = []
  end

  def test_create_rejects_generator_class_outside_allowlist_when_set
    Passkit.configuration.pass_generators = ["AdminUser"]
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserStoreCard, User.find(1))
    get passes_api_path(payload)
    assert_response :not_found
  ensure
    Passkit.configuration.pass_generators = []
  end

  def test_create_with_unknown_collection_name_returns_404
    user = User.find(1)
    payload = Passkit::UrlEncrypt.encrypt(
      valid_until: 30.days.from_now,
      generator_class: "User",
      generator_id: user.id,
      pass_class: Passkit::UserTicket.name,
      collection_name: "send_email_to_attacker"
    )
    get passes_api_path(payload)
    assert_response :not_found
  end

  def test_show_regenerates_pkpass_on_each_request
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :success
    first_body = response.body
    refute_empty first_body
    first_zip = Zip::File.open_buffer(StringIO.new(first_body))
    assert_includes first_zip.entries.map(&:name), "pass.json"

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
    assert_response :success
    second_body = response.body
    refute_empty second_body
    second_zip = Zip::File.open_buffer(StringIO.new(second_body))
    assert_includes second_zip.entries.map(&:name), "pass.json"
  end

  # ------------------------------------------------------------------
  # If-Modified-Since boundary handling
  # ------------------------------------------------------------------

  def test_show_returns_304_when_if_modified_since_equals_last_update
    # Boundary: controller compares with `>` so equal-to means "not modified".
    # Apple Wallet polls with the previously-served Last-Modified value, so an
    # equal comparison must short-circuit — otherwise iOS re-downloads on every
    # poll cycle and burns bandwidth.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last

    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "If-Modified-Since" => pass.last_update.httpdate}
    assert_response :not_modified
    assert_equal "", response.body
  end

  def test_show_returns_200_when_if_modified_since_is_one_second_before_last_update
    # Boundary: 1s stale → must re-serve the body. Pin against accidental
    # `>=` regressions which would mistakenly 304 when content is newer.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last

    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "If-Modified-Since" => (pass.last_update - 1.second).httpdate}
    assert_response :success
    refute_empty response.body
  end

  def test_show_returns_200_when_if_modified_since_is_far_in_past
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last

    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}",
                "If-Modified-Since" => 1.year.ago.httpdate}
    assert_response :success
  end

  # ------------------------------------------------------------------
  # Auth header malformed handling — pinning current loose parser
  # ------------------------------------------------------------------

  def test_show_returns_unauthorized_for_authorization_header_with_empty_token
    # `ApplePass ` (trailing space, empty token) → `split(" ").last` returns
    # "ApplePass" itself, which won't match any real token, so 401.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass "}
    assert_response :unauthorized
  end

  # NB: the controller's `request.headers["Authorization"]&.split(" ")&.last`
  # accepts ANY scheme as long as the trailing token matches a stored
  # authentication_token. This pin documents the looseness; tightening to
  # require the literal "ApplePass " prefix would be a backwards-incompatible
  # change. Real Apple Wallet always sends "ApplePass <hex>" so this loose
  # parsing isn't actually exploited in practice.
  def test_show_accepts_bearer_scheme_when_token_matches_pinning_loose_parser
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "Bearer #{pass.authentication_token}"}
    assert_response :success,
      "the controller's `split(' ').last` parser intentionally ignores the scheme; " \
      "if this test starts failing because of a tightening, update the test + flag the breaking change"
  end

  def test_show_accepts_arbitrary_scheme_prefix_when_token_matches_pinning_loose_parser
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      headers: {"Authorization" => "Foo Bar #{pass.authentication_token}"}
    assert_response :success
  end

  def test_show_token_from_other_pass_does_not_authenticate_this_pass
    # Cross-pass token reuse is the real-world risk: a malicious client that
    # got hold of pass A's token must not be able to fetch pass B with it.
    # `Pass.find_by(serial_number: ..., authentication_token: ...)` enforces
    # the AND, but pin it.
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass_a, pass_b = Passkit::Pass.order(:id).to_a
    refute_equal pass_a.serial_number, pass_b.serial_number
    refute_equal pass_a.authentication_token, pass_b.authentication_token

    get pass_path(pass_type_id: pass_b.pass_type_identifier, serial_number: pass_b.serial_number),
      headers: {"Authorization" => "ApplePass #{pass_a.authentication_token}"}
    assert_response :unauthorized
  end

  # ------------------------------------------------------------------
  # User-Agent detection edge cases
  # ------------------------------------------------------------------

  def test_create_collection_with_missing_user_agent_renders_html_index
    # Missing UA must NOT serve a `.pkpasses` bundle; non-Wallet clients
    # cannot open it. UrlGenerator returns the same URL for iOS and Android,
    # so this fallback is what protects all non-iOS callers.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload)
    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
  end

  def test_create_collection_with_empty_user_agent_renders_html_index
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => ""}
    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
  end

  def test_create_collection_with_lowercase_passkit_ua_renders_html_index
    # The regex `\A(PassKit|Wallet)/` is case-sensitive on purpose — Apple
    # always sends the canonical PascalCase form. Lowercase indicates a
    # spoof or a misconfigured proxy and should fall back to HTML.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "passkit/1.0"}
    assert_response :success
    assert_equal "text/html", response.headers["Content-Type"].split(";").first
  end

  def test_create_collection_with_apple_watch_wallet_ua_serves_pkpasses_bundle
    # Apple Watch fetches its companion Wallet content with a "Wallet/<ver>"
    # UA prefix too. Pin that the regex matches it (it does, because `\A` only
    # anchors at the start; the suffix doesn't matter).
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "Wallet/8.0 watchOS/10.0"}
    assert_response :success
    assert_equal "application/vnd.apple.pkpasses", response.headers["Content-Type"].split(";").first
  end

  # ------------------------------------------------------------------
  # `.pkpasses` bundle — every nested entry independently valid
  # ------------------------------------------------------------------

  def test_create_apple_wallet_ua_for_collection_serves_independently_valid_pkpass_entries
    # Recursive validation: each inner .pkpass must have all 4 required
    # entries AND its signature must verify against our test CA. This is the
    # strongest end-to-end check on iOS Wallet's bundle path.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "PassKit/1.0 CFNetwork/1410 Darwin/22.0.0"}
    assert_response :success
    assert_equal "application/vnd.apple.pkpasses", response.headers["Content-Type"].split(";").first

    inner_passes = PkpassHelpers.read_pkpasses_bundle(response.body)
    assert_equal 2, inner_passes.size, "two tickets should produce two inner passes"
    inner_passes.each do |pkpass|
      PkpassHelpers::REQUIRED_PKPASS_ENTRIES.each do |required|
        assert_includes pkpass[:entry_names], required
      end
      assert pkpass[:entry_names].any? { |n| n == "icon.png" }, "icon.png required"
      assert PkpassHelpers.verify_pkpass_signature!(pkpass)
      assert PkpassHelpers.assert_valid_pass_json(pkpass[:pass_json], pass_type: :eventTicket)
    end
  end

  # ------------------------------------------------------------------
  # HTML index → click-through flow (Android lifecycle's critical step)
  # ------------------------------------------------------------------

  def test_html_index_link_click_returns_valid_single_pkpass
    # End-to-end: Android browser receives HTML index → user clicks first
    # link → browser GETs that URL → returns a single signed `.pkpass`
    # ready to hand to PassWallet (or whatever opens vnd.apple.pkpass on
    # the device). Pin the entire round-trip including signature verify.
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14; Pixel 7)"}
    assert_response :success

    href_match = response.body.match(/href="([^"]+)"/)
    refute_nil href_match, "expected at least one <a href> in HTML index"
    href = href_match[1].gsub("&amp;", "&")
    payload_segment = href.split("/").last
    refute_empty payload_segment

    get passes_api_path(payload_segment), headers: {"User-Agent" => "Mozilla/5.0 (Linux; Android 14; Pixel 7)"}
    assert_response :success
    assert_equal "application/vnd.apple.pkpass", response.headers["Content-Type"].split(";").first

    pkpass = PkpassHelpers.read_pkpass(response.body)
    PkpassHelpers::REQUIRED_PKPASS_ENTRIES.each { |req| assert_includes pkpass[:entry_names], req }
    assert PkpassHelpers.verify_pkpass_signature!(pkpass)
  end

  # ------------------------------------------------------------------
  # valid_until boundary
  # ------------------------------------------------------------------

  def test_create_with_valid_until_one_second_in_past_returns_404
    # `valid_until_in_future?` uses `parsed.past?`, which is strictly < now.
    # Freeze time so the test is deterministic regardless of CI clock skew.
    travel_to Time.zone.local(2026, 6, 1, 12, 0, 0) do
      payload = encrypted_payload(Passkit::ExampleStoreCard, valid_until: 1.second.ago)
      get passes_api_path(payload)
      assert_response :not_found
    end
  end

  def test_create_with_valid_until_one_second_in_future_returns_200
    travel_to Time.zone.local(2026, 6, 1, 12, 0, 0) do
      payload = encrypted_payload(Passkit::ExampleStoreCard, valid_until: 1.second.from_now)
      get passes_api_path(payload)
      assert_response :success
    end
  end

  # ------------------------------------------------------------------
  # Allowlist — backwards-compatibility pin
  # ------------------------------------------------------------------

  def test_create_with_empty_pass_classes_allowlist_allows_all
    # Empty allowlist == no enforcement. Pin so a future change accidentally
    # treating empty-array as deny-all doesn't silently 404 every host app
    # that hasn't configured allowlists.
    Passkit.configuration.pass_classes = []
    payload = encrypted_payload(Passkit::ExampleStoreCard)
    get passes_api_path(payload)
    assert_response :success
  end

  private

  def encrypted_payload(pass_class, generator: nil, collection_name: nil, valid_until: 30.days.from_now)
    hash = {
      valid_until: valid_until,
      generator_class: generator&.class&.name,
      generator_id: generator&.id,
      pass_class: pass_class.name,
      collection_name: collection_name
    }
    Passkit::UrlEncrypt.encrypt(hash)
  end
end
