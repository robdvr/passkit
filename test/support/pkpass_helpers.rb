# frozen_string_literal: true

require "openssl"
require "json"
require "stringio"
require "zip"
require "digest"

# Test helpers for opening generated `.pkpass` and `.pkpasses` archives and
# verifying their structure + signature against the ephemeral CA produced by
# `Passkit::CertHelper`. Used by Generator, controller, and integration tests
# so signature/manifest assertions stay centralized.
module PkpassHelpers
  REQUIRED_PKPASS_ENTRIES = %w[pass.json manifest.json signature].freeze

  module_function

  # Reads a `.pkpass` from a Pathname/String path or in-memory bytes (String /
  # IO). Returns a hash:
  #   {pass_json:, manifest:, signature_bytes:, entry_names:, entry_bytes:}
  def read_pkpass(source)
    bytes = source_to_bytes(source)
    # `Zip::File.open_buffer { ... }` returns the underlying StringIO, not the
    # block value — capture explicitly via a local.
    result = nil
    Zip::File.open_buffer(StringIO.new(bytes)) do |zf|
      entries = zf.entries.map(&:name)
      entry_bytes = entries.each_with_object({}) { |n, h| h[n] = zf.read(n) }
      result = {
        pass_json: JSON.parse(entry_bytes.fetch("pass.json")),
        manifest: JSON.parse(entry_bytes.fetch("manifest.json")),
        signature_bytes: entry_bytes.fetch("signature"),
        entry_names: entries,
        entry_bytes: entry_bytes
      }
    end
    result
  end

  # Reads a `.pkpasses` bundle and returns an array of `read_pkpass` hashes,
  # one per inner `.pkpass`. Asserts each entry name ends with `.pkpass`.
  def read_pkpasses_bundle(source)
    bytes = source_to_bytes(source)
    result = nil
    Zip::File.open_buffer(StringIO.new(bytes)) do |zf|
      result = zf.entries.map do |entry|
        unless entry.name.end_with?(".pkpass")
          raise "expected `.pkpasses` entry to end with .pkpass, got #{entry.name.inspect}"
        end
        read_pkpass(entry.get_input_stream.read)
      end
    end
    result
  end

  # Mathematically verifies a `.pkpass`'s detached PKCS7 signature against the
  # ephemeral test CA written by `Passkit::CertHelper`. Returns true on success;
  # raises with a descriptive message on failure so the test message points at
  # the underlying OpenSSL error rather than just `false`.
  def verify_pkpass_signature!(pkpass)
    pkcs7 = OpenSSL::PKCS7.new(pkpass[:signature_bytes])
    manifest_bytes = pkpass[:entry_bytes].fetch("manifest.json")
    store = test_ca_store
    flags = OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY
    ok = pkcs7.verify([], store, manifest_bytes, flags)
    return true if ok
    raise "PKCS7#verify returned false; OpenSSL error: #{pkcs7.error_string.inspect}"
  end

  # Returns an X509::Store loaded with the test intermediate CA cert from
  # PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE. Built fresh per call to keep the
  # test suite hermetic; no on-disk trust store changes.
  def test_ca_store
    store = OpenSSL::X509::Store.new
    cert_path = ENV.fetch("PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE")
    store.add_cert(OpenSSL::X509::Certificate.new(File.binread(cert_path)))
    store
  end

  # Asserts a parsed pass.json hash is structurally valid for the given
  # pass_type. Hand-rolled per-field — see `BasePass` and `Generator#generate_json_pass`
  # for the source of truth. Raises with descriptive messages.
  ALWAYS_REQUIRED_KEYS = %w[
    formatVersion teamIdentifier authenticationToken backgroundColor
    description foregroundColor labelColor logoText organizationName
    passTypeIdentifier serialNumber webServiceURL
  ].freeze

  RGB_REGEX = /\Argb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)\z/

  PASS_TYPE_BLOCK_KEYS = %w[storeCard coupon eventTicket generic boardingPass].freeze

  FIELD_BLOCK_SUBKEYS = %w[headerFields primaryFields secondaryFields auxiliaryFields backFields].freeze

  # `enhanced_event_ticket: true` additionally asserts the iOS 18+ poster-style
  # keys (`preferredStyleSchemes`, `eventLogoText`, `additionalInfoFields`,
  # `relevantDates`) are present and well-shaped — used by the lifecycle test
  # for the upgraded UserTicket. Default `false` keeps existing call sites
  # working.
  def assert_valid_pass_json(pass_json, pass_type:, enhanced_event_ticket: false)
    raise ArgumentError, "pass_json must be Hash, got #{pass_json.class}" unless pass_json.is_a?(Hash)

    ALWAYS_REQUIRED_KEYS.each do |key|
      raise "pass.json missing required key #{key}" unless pass_json.key?(key)
    end

    raise "formatVersion must be Integer, got #{pass_json["formatVersion"].class}" unless pass_json["formatVersion"].is_a?(Integer)
    %w[teamIdentifier passTypeIdentifier serialNumber authenticationToken description organizationName logoText webServiceURL].each do |k|
      raise "#{k} must be String, got #{pass_json[k].class}" unless pass_json[k].is_a?(String)
    end
    %w[backgroundColor foregroundColor labelColor].each do |k|
      raise "#{k} must match rgb(r,g,b), got #{pass_json[k].inspect}" unless pass_json[k].is_a?(String) && pass_json[k].match?(RGB_REGEX)
    end
    %w[sharingProhibited suppressStripShine voided].each do |k|
      raise "#{k} must be true/false, got #{pass_json[k].inspect}" unless [true, false].include?(pass_json[k])
    end
    raise "webServiceURL must be https://, got #{pass_json["webServiceURL"].inspect}" unless pass_json["webServiceURL"].start_with?("https://")

    expected_block = pass_type.to_s
    unless PASS_TYPE_BLOCK_KEYS.include?(expected_block)
      raise "unknown pass_type #{pass_type.inspect} (expected one of #{PASS_TYPE_BLOCK_KEYS.inspect})"
    end
    raise "expected pass.json to have #{expected_block} block, got keys #{pass_json.keys.inspect}" unless pass_json[expected_block].is_a?(Hash)

    block = pass_json[expected_block]
    FIELD_BLOCK_SUBKEYS.each do |sub|
      raise "#{expected_block}.#{sub} must be Array, got #{block[sub].inspect}" unless block[sub].is_a?(Array)
    end

    if pass_json.key?("barcodes")
      raise "barcodes must be non-empty Array" unless pass_json["barcodes"].is_a?(Array) && !pass_json["barcodes"].empty?
      pass_json["barcodes"].each do |bc|
        raise "barcode entry must specify format" unless bc.is_a?(Hash) && bc["format"].is_a?(String) && bc["format"].start_with?("PKBarcodeFormat")
        raise "barcode entry must specify message" unless bc["message"].is_a?(String)
      end
      raise "pass.json must not include both barcode and barcodes" if pass_json.key?("barcode")
    elsif pass_json.key?("barcode")
      bc = pass_json["barcode"]
      raise "barcode must be Hash" unless bc.is_a?(Hash)
      raise "barcode.format must be PKBarcodeFormat*" unless bc["format"].is_a?(String) && bc["format"].start_with?("PKBarcodeFormat")
    end

    raise "locations must be Array (got #{pass_json["locations"].class})" unless pass_json["locations"].is_a?(Array) || pass_json["locations"].nil?

    if pass_json.key?("expirationDate")
      raise "expirationDate must be ISO8601 String" unless pass_json["expirationDate"].is_a?(String) && parseable_iso8601?(pass_json["expirationDate"])
    end
    if pass_json.key?("relevantDate")
      raise "relevantDate must be ISO8601 String" unless pass_json["relevantDate"].is_a?(String) && parseable_iso8601?(pass_json["relevantDate"])
    end

    assert_enhanced_event_ticket_keys!(pass_json) if enhanced_event_ticket

    true
  end

  def assert_enhanced_event_ticket_keys!(pass_json)
    raise "enhanced eventTicket: preferredStyleSchemes missing" unless pass_json["preferredStyleSchemes"].is_a?(Array)
    raise "enhanced eventTicket: preferredStyleSchemes must include 'posterEventTicket'" unless pass_json["preferredStyleSchemes"].include?("posterEventTicket")
    raise "enhanced eventTicket: eventLogoText missing or wrong type" unless pass_json["eventLogoText"].is_a?(String)
    raise "enhanced eventTicket: additionalInfoFields must be non-empty Array" unless pass_json["additionalInfoFields"].is_a?(Array) && !pass_json["additionalInfoFields"].empty?
    pass_json["additionalInfoFields"].each_with_index do |f, i|
      raise "enhanced eventTicket: additionalInfoFields[#{i}].key/value required" unless f.is_a?(Hash) && f["key"].is_a?(String) && !f["value"].nil?
    end
    raise "enhanced eventTicket: relevantDates must be non-empty Array" unless pass_json["relevantDates"].is_a?(Array) && !pass_json["relevantDates"].empty?
    pass_json["relevantDates"].each_with_index do |d, i|
      raise "enhanced eventTicket: relevantDates[#{i}].startDate must be ISO 8601" unless d.is_a?(Hash) && parseable_iso8601?(d["startDate"])
    end
    sem = pass_json["semantics"]
    raise "enhanced eventTicket: semantics must be Hash" unless sem.is_a?(Hash)
    raise "enhanced eventTicket: semantics.eventName required" unless sem["eventName"].is_a?(String)
    raise "enhanced eventTicket: semantics.eventType required" unless sem["eventType"].is_a?(String) && sem["eventType"].start_with?("PKEventType")
    raise "enhanced eventTicket: semantics.venueName required" unless sem["venueName"].is_a?(String)
    raise "enhanced eventTicket: semantics.venueLocation required" unless sem["venueLocation"].is_a?(Hash)
    %w[eventStartDate eventEndDate].each do |k|
      raise "enhanced eventTicket: semantics.#{k} must be ISO 8601" unless parseable_iso8601?(sem[k])
    end
    true
  end

  def parseable_iso8601?(string)
    Time.iso8601(string)
    true
  rescue ArgumentError
    false
  end

  def source_to_bytes(source)
    case source
    when String
      # Heuristic: looks like a path? Read it. Otherwise treat as bytes.
      if source.bytesize < 4096 && File.exist?(source)
        File.binread(source)
      else
        source
      end
    when Pathname
      File.binread(source)
    when StringIO, IO
      source.binmode if source.respond_to?(:binmode)
      source.read
    else
      raise ArgumentError, "unsupported source type #{source.class}"
    end
  end
end
