# frozen_string_literal: true

require "openssl"
require "fileutils"

# Generates an ephemeral throwaway p12 + Apple-WWDR-style intermediate
# certificate at suite startup so `Passkit::Generator#sign_manifest` can run
# without committing real Apple credentials. The signature is not Apple-valid;
# the goal is to exercise the OpenSSL::PKCS7 code path and verify structure.
#
# Files are written under `tmp/passkit_test_certs/` (relative to repo root)
# and `ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"]` /
# `ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"]` are set to absolute paths
# so `Rails.root.join(...)` in `lib/passkit/generator.rb` resolves correctly.
module Passkit
  module CertHelper
    PASSWORD = "test-cert-password"

    class << self
      def install!
        return if @installed
        certs_dir = repo_root.join("tmp", "passkit_test_certs")
        FileUtils.mkdir_p(certs_dir)

        intermediate_path = certs_dir.join("intermediate.cer")
        p12_path = certs_dir.join("pass.p12")

        unless intermediate_path.exist? && p12_path.exist?
          generate_certs(intermediate_path, p12_path)
        end

        ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"] ||= p12_path.to_s
        ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"] ||= intermediate_path.to_s
        ENV["PASSKIT_CERTIFICATE_KEY"] ||= PASSWORD
        ENV["PASSKIT_WEB_SERVICE_HOST"] ||= "https://example.test"
        ENV["PASSKIT_APPLE_TEAM_IDENTIFIER"] ||= "TESTTEAMID"
        ENV["PASSKIT_PASS_TYPE_IDENTIFIER"] ||= "pass.com.example.test"
        ENV["PASSKIT_DASHBOARD_USERNAME"] ||= "admin"
        ENV["PASSKIT_DASHBOARD_PASSWORD"] ||= "admin"
        ENV["PASSKIT_URL_ENCRYPTION_KEY"] ||= "0123456789abcdef0123456789abcdef"
        @installed = true
      end

      def password
        PASSWORD
      end

      private

      def repo_root
        Pathname.new(File.expand_path("../..", __dir__))
      end

      def generate_certs(intermediate_path, p12_path)
        # Self-signed "intermediate" CA cert (stand-in for AppleWWDRCA).
        ca_key = OpenSSL::PKey::RSA.new(2048)
        ca_cert = OpenSSL::X509::Certificate.new
        ca_cert.version = 2
        ca_cert.serial = 1
        ca_cert.subject = OpenSSL::X509::Name.parse("/CN=Passkit Test Intermediate CA")
        ca_cert.issuer = ca_cert.subject
        ca_cert.public_key = ca_key.public_key
        ca_cert.not_before = Time.now - 60
        ca_cert.not_after = Time.now + (10 * 365 * 24 * 60 * 60)
        ca_ef = OpenSSL::X509::ExtensionFactory.new
        ca_ef.subject_certificate = ca_cert
        ca_ef.issuer_certificate = ca_cert
        ca_cert.add_extension(ca_ef.create_extension("basicConstraints", "CA:TRUE", true))
        ca_cert.add_extension(ca_ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        ca_cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))

        # Leaf "pass-signing" cert issued by the intermediate.
        leaf_key = OpenSSL::PKey::RSA.new(2048)
        leaf_cert = OpenSSL::X509::Certificate.new
        leaf_cert.version = 2
        leaf_cert.serial = 2
        leaf_cert.subject = OpenSSL::X509::Name.parse("/CN=Passkit Test Pass Signing")
        leaf_cert.issuer = ca_cert.subject
        leaf_cert.public_key = leaf_key.public_key
        leaf_cert.not_before = Time.now - 60
        leaf_cert.not_after = Time.now + (10 * 365 * 24 * 60 * 60)
        leaf_ef = OpenSSL::X509::ExtensionFactory.new
        leaf_ef.subject_certificate = leaf_cert
        leaf_ef.issuer_certificate = ca_cert
        leaf_cert.add_extension(leaf_ef.create_extension("basicConstraints", "CA:FALSE", true))
        leaf_cert.add_extension(leaf_ef.create_extension("keyUsage", "digitalSignature", true))
        leaf_cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))

        File.binwrite(intermediate_path, ca_cert.to_der)

        p12 = OpenSSL::PKCS12.create(PASSWORD, "Passkit Test", leaf_key, leaf_cert)
        File.binwrite(p12_path, p12.to_der)
      end
    end
  end
end
