module Passkit
  class UrlEncrypt
    # Format: VERSION_BYTE + IV(hex) + AUTH_TAG(hex) + ciphertext(hex), uppercase.
    # Version byte 02 = AES-256-GCM, 12-byte nonce, 16-byte authentication tag,
    # key derived via Digest::SHA256 over PASSKIT_URL_ENCRYPTION_KEY (or
    # secret_key_base when the env var is unset). GCM provides authenticated
    # encryption — any tampering with the URL fails decrypt with CipherError.
    VERSION_BYTE = "02".freeze
    IV_HEX_LEN = 24       # 12 bytes nonce * 2
    AUTH_TAG_HEX_LEN = 32 # 16 bytes tag * 2
    CIPHER_NAME = "AES-256-GCM".freeze

    class << self
      def encrypt(payload)
        cipher = build_cipher.encrypt
        cipher.key = encryption_key
        iv = cipher.random_iv
        cipher.auth_data = ""
        ciphertext = cipher.update(payload.to_json) + cipher.final
        tag = cipher.auth_tag
        (VERSION_BYTE + iv.unpack1("H*") + tag.unpack1("H*") + ciphertext.unpack1("H*")).upcase
      end

      def decrypt(string)
        unless valid_format?(string)
          raise OpenSSL::Cipher::CipherError, "unrecognized passkit URL payload format"
        end

        body = string[VERSION_BYTE.length..]
        iv = [body[0, IV_HEX_LEN]].pack("H*")
        tag = [body[IV_HEX_LEN, AUTH_TAG_HEX_LEN]].pack("H*")
        ciphertext = [body[(IV_HEX_LEN + AUTH_TAG_HEX_LEN)..]].pack("H*")
        cipher = build_cipher.decrypt
        cipher.key = encryption_key
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = ""
        JSON.parse(cipher.update(ciphertext) + cipher.final, symbolize_names: true)
      end

      private

      def valid_format?(string)
        return false unless string.is_a?(String)
        return false unless string.upcase.start_with?(VERSION_BYTE.upcase)
        string.length > VERSION_BYTE.length + IV_HEX_LEN + AUTH_TAG_HEX_LEN
      end

      def encryption_key
        raw = ENV.fetch("PASSKIT_URL_ENCRYPTION_KEY") { Rails.application.secret_key_base }
        Digest::SHA256.digest(raw)
      end

      def build_cipher
        OpenSSL::Cipher.new(CIPHER_NAME)
      end
    end
  end
end
