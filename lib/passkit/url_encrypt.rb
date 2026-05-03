module Passkit
  class UrlEncrypt
    # Format: "01" + IV(32 hex) + ciphertext(hex), all uppercase.
    # Version byte 01 = AES-256-CBC with random per-encrypt IV; key derived
    # via Digest::SHA256 over PASSKIT_URL_ENCRYPTION_KEY (or secret_key_base).
    VERSION_BYTE = "01".freeze
    IV_HEX_LEN = 32 # 16 bytes * 2 hex chars
    CIPHER_NAME = "AES-256-CBC".freeze

    class << self
      def encrypt(payload)
        cipher = build_cipher.encrypt
        cipher.key = encryption_key
        iv = cipher.random_iv
        ciphertext = cipher.update(payload.to_json) + cipher.final
        (VERSION_BYTE + iv.unpack1("H*") + ciphertext.unpack1("H*")).upcase
      end

      def decrypt(string)
        unless string.is_a?(String) && string.length > VERSION_BYTE.length + IV_HEX_LEN && string.start_with?(VERSION_BYTE.upcase, VERSION_BYTE)
          raise OpenSSL::Cipher::CipherError, "unrecognized passkit URL payload format"
        end

        body = string[VERSION_BYTE.length..]
        iv = [body[0, IV_HEX_LEN]].pack("H*")
        ciphertext = [body[IV_HEX_LEN..]].pack("H*")
        cipher = build_cipher.decrypt
        cipher.key = encryption_key
        cipher.iv = iv
        JSON.parse(cipher.update(ciphertext) + cipher.final, symbolize_names: true)
      end

      private

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
