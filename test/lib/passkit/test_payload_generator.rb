# frozen_string_literal: true

require "rails_helper"

class TestPayloadGenerator < ActiveSupport::TestCase
  def test_hash_returns_expected_keys_with_no_generator
    freeze_time do
      result = Passkit::PayloadGenerator.hash(Passkit::ExampleStoreCard)

      assert_equal 30.days.from_now, result[:valid_until]
      assert_nil result[:generator_class]
      assert_nil result[:generator_id]
      assert_equal "Passkit::ExampleStoreCard", result[:pass_class]
      assert_nil result[:collection_name]
    end
  end

  def test_hash_with_active_record_generator
    user = User.find(1)
    result = Passkit::PayloadGenerator.hash(Passkit::ExampleStoreCard, user)

    assert_equal "User", result[:generator_class]
    assert_equal 1, result[:generator_id]
  end

  def test_hash_with_collection_name
    user = User.find(1)
    result = Passkit::PayloadGenerator.hash(Passkit::ExampleStoreCard, user, :tickets)

    assert_equal :tickets, result[:collection_name]
  end

  def test_pass_class_is_class_name_string
    result = Passkit::PayloadGenerator.hash(Passkit::ExampleStoreCard)

    assert_equal "Passkit::ExampleStoreCard", result[:pass_class]
    assert_kind_of String, result[:pass_class]
  end

  def test_validity_constant_is_30_days
    assert_equal 30.days, Passkit::PayloadGenerator::VALIDITY
  end

  def test_encrypted_round_trips_through_url_encrypt
    freeze_time do
      user = User.find(1)
      encrypted = Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard, user, :tickets)
      decrypted = Passkit::UrlEncrypt.decrypt(encrypted)

      assert_equal "Passkit::ExampleStoreCard", decrypted[:pass_class]
      assert_equal "User", decrypted[:generator_class]
      assert_equal 1, decrypted[:generator_id]
      assert_equal "tickets", decrypted[:collection_name]
      assert_kind_of String, decrypted[:valid_until]
    end
  end

  def test_encrypted_output_is_hex_string
    encrypted = Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard)

    assert_match(/\A[0-9A-F]+\z/, encrypted)
  end
end
