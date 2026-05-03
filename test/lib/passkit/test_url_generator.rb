# frozen_string_literal: true

require "rails_helper"

class TestUrlGenerator < ActiveSupport::TestCase
  def test_ios_returns_url_with_passes_api_route
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard)
    url = g.ios

    assert_includes url, "/passkit/api/v1/passes/"
  end

  def test_ios_url_uses_PASSKIT_WEB_SERVICE_HOST
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard)

    assert g.ios.start_with?(ENV["PASSKIT_WEB_SERVICE_HOST"]),
      "expected #{g.ios.inspect} to start with #{ENV["PASSKIT_WEB_SERVICE_HOST"].inspect}"
  end

  def test_ios_payload_round_trips
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard)
    payload = g.ios.split("/").last
    decrypted = Passkit::UrlEncrypt.decrypt(payload)

    assert_equal "Passkit::ExampleStoreCard", decrypted[:pass_class]
  end

  def test_ios_payload_includes_generator_when_provided
    user = User.find(1)
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard, user)
    payload = g.ios.split("/").last
    decrypted = Passkit::UrlEncrypt.decrypt(payload)

    assert_equal "User", decrypted[:generator_class]
    assert_equal 1, decrypted[:generator_id]
  end

  def test_ios_payload_includes_collection_name_when_provided
    user = User.find(1)
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard, user, :tickets)
    payload = g.ios.split("/").last
    decrypted = Passkit::UrlEncrypt.decrypt(payload)

    assert_equal "tickets", decrypted[:collection_name]
  end

  def test_android_prepends_walletpass_io
    g = Passkit::UrlGenerator.new(Passkit::ExampleStoreCard)

    assert_equal "https://walletpass.io?u=" + g.ios, g.android
  end

  def test_android_constant
    assert_equal "https://walletpass.io?u=", Passkit::UrlGenerator::WALLET_PASS_PREFIX
  end
end
