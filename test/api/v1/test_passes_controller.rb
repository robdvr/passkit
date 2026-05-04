# frozen_string_literal: true

require "rails_helper"

class TestPassesController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

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
