# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TestUrlEncrypt < Minitest::Test
  ENCRYPTION_KEY_VAR = "PASSKIT_URL_ENCRYPTION_KEY"

  def with_env(overrides)
    saved = {}
    overrides.each_key { |k| saved[k] = ENV[k] }
    begin
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  def test_round_trip_with_simple_hash
    payload = {a: 1, b: "two", c: nil}
    encrypted = Passkit::UrlEncrypt.encrypt(payload)
    decrypted = Passkit::UrlEncrypt.decrypt(encrypted)
    assert_equal payload, decrypted
  end

  def test_round_trip_with_nested_hash
    payload = {outer: {inner: [1, 2, 3]}}
    encrypted = Passkit::UrlEncrypt.encrypt(payload)
    decrypted = Passkit::UrlEncrypt.decrypt(encrypted)
    assert_equal payload, decrypted
  end

  def test_round_trip_with_string_keys
    # JSON.parse(symbolize_names: true) converts string keys to symbols on decode.
    encrypted = Passkit::UrlEncrypt.encrypt({"a" => 1})
    assert_equal({a: 1}, Passkit::UrlEncrypt.decrypt(encrypted))
  end

  def test_output_is_uppercase_hex
    output = Passkit::UrlEncrypt.encrypt({foo: "bar"})
    assert_match(/\A[0-9A-F]+\z/, output)
  end

  def test_decrypt_with_wrong_key_raises
    encrypted = Passkit::UrlEncrypt.encrypt({foo: "bar"})
    with_env(ENCRYPTION_KEY_VAR => "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ") do
      assert_raises(OpenSSL::Cipher::CipherError) do
        Passkit::UrlEncrypt.decrypt(encrypted)
      end
    end
  end

  def test_uses_PASSKIT_URL_ENCRYPTION_KEY_when_set
    payload = {hello: "world"}
    with_env(ENCRYPTION_KEY_VAR => "AAAAAAAAAAAAAAAA_padding_padding") do
      out_a = Passkit::UrlEncrypt.encrypt(payload)
      assert_equal payload, Passkit::UrlEncrypt.decrypt(out_a)

      with_env(ENCRYPTION_KEY_VAR => "BBBBBBBBBBBBBBBB_padding_padding") do
        out_b = Passkit::UrlEncrypt.encrypt(payload)
        assert_equal payload, Passkit::UrlEncrypt.decrypt(out_b)
        # Different keys produce different ciphertexts for the same plaintext.
        refute_equal out_a, out_b
      end
    end
  end

  def test_falls_back_to_secret_key_base_when_env_unset
    payload = {foo: "bar"}
    fake_app = Object.new
    def fake_app.secret_key_base
      "abcdefghij0123456789ZZZZZZZZZZZZ"
    end

    with_env(ENCRYPTION_KEY_VAR => nil) do
      Rails.stubs(:application).returns(fake_app)
      out1 = Passkit::UrlEncrypt.encrypt(payload)
      # With per-encrypt random IV the ciphertext varies; both still decrypt.
      out2 = Passkit::UrlEncrypt.encrypt(payload)
      refute_equal out1, out2
      assert_equal payload, Passkit::UrlEncrypt.decrypt(out1)
      assert_equal payload, Passkit::UrlEncrypt.decrypt(out2)
    end
  end

  def test_random_iv_produces_distinct_ciphertexts_for_identical_plaintext
    a = Passkit::UrlEncrypt.encrypt({x: 1})
    b = Passkit::UrlEncrypt.encrypt({x: 1})
    refute_equal a, b
    assert_equal({x: 1}, Passkit::UrlEncrypt.decrypt(a))
    assert_equal({x: 1}, Passkit::UrlEncrypt.decrypt(b))
  end

  def test_key_uses_full_input_via_sha256_derivation
    payload = {x: 1}

    out_a = with_env(ENCRYPTION_KEY_VAR => "abcdefghijklmnop_TAIL_DATA_CHANGES") do
      Passkit::UrlEncrypt.encrypt(payload)
    end
    out_b = with_env(ENCRYPTION_KEY_VAR => "abcdefghijklmnop_DIFFERENT_TAIL") do
      Passkit::UrlEncrypt.encrypt(payload)
    end

    # Different tails ⇒ different SHA256 derivations ⇒ output cannot decrypt
    # under the other key.
    refute_equal out_a, out_b
    with_env(ENCRYPTION_KEY_VAR => "abcdefghijklmnop_DIFFERENT_TAIL") do
      assert_raises(OpenSSL::Cipher::CipherError) { Passkit::UrlEncrypt.decrypt(out_a) }
    end
  end

  def test_output_starts_with_format_version_byte
    output = Passkit::UrlEncrypt.encrypt({foo: "bar"})
    assert_equal Passkit::UrlEncrypt::VERSION_BYTE.upcase, output[0, 2]
  end

  def test_decrypt_rejects_unrecognized_format
    assert_raises(OpenSSL::Cipher::CipherError) do
      Passkit::UrlEncrypt.decrypt("DEADBEEF")
    end
  end

  def test_format_is_aes_256_gcm_v2
    assert_equal "AES-256-GCM", Passkit::UrlEncrypt::CIPHER_NAME
    assert_equal "02", Passkit::UrlEncrypt::VERSION_BYTE
  end

  def test_decrypt_rejects_tampered_ciphertext
    # Use a payload long enough to give us bytes to flip past version+IV+tag.
    encrypted = Passkit::UrlEncrypt.encrypt({foo: "0123456789ABCDEFGHIJ"})
    ciphertext_offset = Passkit::UrlEncrypt::VERSION_BYTE.length +
      Passkit::UrlEncrypt::IV_HEX_LEN +
      Passkit::UrlEncrypt::AUTH_TAG_HEX_LEN
    tampered = encrypted.dup
    tampered[ciphertext_offset] = ((tampered[ciphertext_offset] == "0") ? "1" : "0")
    assert_raises(OpenSSL::Cipher::CipherError) { Passkit::UrlEncrypt.decrypt(tampered) }
  end

  def test_decrypt_rejects_tampered_auth_tag
    encrypted = Passkit::UrlEncrypt.encrypt({foo: "bar"})
    tag_offset = Passkit::UrlEncrypt::VERSION_BYTE.length + Passkit::UrlEncrypt::IV_HEX_LEN
    tampered = encrypted.dup
    tampered[tag_offset] = ((tampered[tag_offset] == "0") ? "1" : "0")
    assert_raises(OpenSSL::Cipher::CipherError) { Passkit::UrlEncrypt.decrypt(tampered) }
  end

  # ------------------------------------------------------------------
  # Format-length boundary
  # ------------------------------------------------------------------

  def test_decrypt_rejects_payload_at_minimum_length_with_no_ciphertext
    # Format requires `length > VERSION_BYTE.length + IV_HEX_LEN + AUTH_TAG_HEX_LEN`
    # (strict, not >=). At exact boundary length there's no ciphertext to
    # decrypt — must raise rather than crash with an obscure OpenSSL error.
    boundary_len = Passkit::UrlEncrypt::VERSION_BYTE.length +
      Passkit::UrlEncrypt::IV_HEX_LEN +
      Passkit::UrlEncrypt::AUTH_TAG_HEX_LEN
    boundary = Passkit::UrlEncrypt::VERSION_BYTE + ("A" * (boundary_len - Passkit::UrlEncrypt::VERSION_BYTE.length))
    assert_equal boundary_len, boundary.length
    assert_raises(OpenSSL::Cipher::CipherError) { Passkit::UrlEncrypt.decrypt(boundary) }
  end

  def test_decrypt_rejects_payload_below_minimum_length
    # 1 char short of the version+IV+tag minimum.
    short = Passkit::UrlEncrypt::VERSION_BYTE + ("A" * (Passkit::UrlEncrypt::IV_HEX_LEN + Passkit::UrlEncrypt::AUTH_TAG_HEX_LEN - 1))
    assert_raises(OpenSSL::Cipher::CipherError) { Passkit::UrlEncrypt.decrypt(short) }
  end

  def test_decrypt_rejects_non_string_input
    [nil, 42, [], {}].each do |bad|
      assert_raises(OpenSSL::Cipher::CipherError) do
        Passkit::UrlEncrypt.decrypt(bad)
      end
    end
  end

  # ------------------------------------------------------------------
  # Parameterized section corruption — pin tampering detection across
  # every distinct region of the ciphertext.
  # ------------------------------------------------------------------

  def test_decrypt_rejects_corruption_in_each_section_individually
    encrypted = Passkit::UrlEncrypt.encrypt({foo: "0123456789ABCDEFGHIJ"})
    iv_offset = Passkit::UrlEncrypt::VERSION_BYTE.length
    tag_offset = iv_offset + Passkit::UrlEncrypt::IV_HEX_LEN
    ct_offset = tag_offset + Passkit::UrlEncrypt::AUTH_TAG_HEX_LEN

    # Corrupt one nibble inside each region. Each must independently fail
    # the auth check and raise.
    {iv: iv_offset, tag: tag_offset, ciphertext: ct_offset}.each do |label, offset|
      corrupted = encrypted.dup
      corrupted[offset] = ((corrupted[offset] == "0") ? "1" : "0")
      assert_raises(OpenSSL::Cipher::CipherError, "tampering of #{label} should be detected") do
        Passkit::UrlEncrypt.decrypt(corrupted)
      end
    end
  end
end
