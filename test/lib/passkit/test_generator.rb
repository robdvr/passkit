# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"
require "zip"
require "json"
require "digest"
require "fileutils"
require "tmpdir"
require_relative "../../support/pkpass_helpers"

class TestGenerator < ActiveSupport::TestCase
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Create a fresh subclass of `Passkit::ExampleStoreCard` with the given
  # method overrides applied via `define_method`. Returns the subclass.
  # The subclass is registered as a const on `Passkit` so it can be
  # `klass.constantize`'d by `Passkit::Pass#instance` (the model stores
  # `klass` as a string and re-resolves it).
  def make_pass_subclass(overrides = {}, parent: Passkit::ExampleStoreCard, &block)
    subclass = Class.new(parent)
    overrides.each do |name, value|
      subclass.define_method(name) { value }
    end
    subclass.class_eval(&block) if block

    const_name = "TestSubclass#{SecureRandom.hex(6)}"
    Passkit.const_set(const_name, subclass)
    @generated_constants ||= []
    @generated_constants << const_name
    subclass
  end

  # Some subclasses need their `pass_path` to point at a real folder
  # containing icon.png. Default to ExampleStoreCard's bundled assets.
  def example_pass_path
    Passkit::ExampleStoreCard.new.pass_path
  end

  def teardown
    super
    @generated_constants&.each do |c|
      Passkit.send(:remove_const, c) if Passkit.const_defined?(c, false)
    end
  end

  # Read pass.json from a generated .pkpass.
  def read_pass_json(pkpass_path)
    Zip::File.open(pkpass_path) do |zf|
      JSON.parse(zf.read("pass.json"))
    end
  end

  def read_manifest(pkpass_path)
    Zip::File.open(pkpass_path) do |zf|
      JSON.parse(zf.read("manifest.json"))
    end
  end

  def read_entry(pkpass_path, name)
    Zip::File.open(pkpass_path) do |zf|
      zf.read(name)
    end
  end

  def entries(pkpass_path)
    Zip::File.open(pkpass_path) { |zf| zf.entries.map(&:name) }
  end

  # ------------------------------------------------------------------
  # check_necessary_files
  # ------------------------------------------------------------------

  def test_raises_when_icon_png_missing
    Dir.mktmpdir do |empty_dir|
      Passkit::ExampleStoreCard.any_instance.stubs(:pass_path).returns(empty_dir)

      err = assert_raises(RuntimeError) do
        Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
      end
      assert_includes err.message, "icon.png is not present"
    end
  end

  # ------------------------------------------------------------------
  # generate_and_sign — end-to-end
  # ------------------------------------------------------------------

  def test_returns_pathname_to_pkpass_file
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_kind_of Pathname, path
    assert path.to_s.end_with?(".pkpass"), "expected #{path} to end with .pkpass"
    assert File.exist?(path)
  end

  def test_pkpass_contains_required_files
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    names = entries(path)
    assert_includes names, "pass.json"
    assert_includes names, "manifest.json"
    assert_includes names, "signature"
    assert names.any? { |n| n == "icon.png" }, "expected at least one icon.png entry, got #{names.inspect}"
  end

  def test_pass_json_has_required_top_level_keys
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)
    %w[
      formatVersion teamIdentifier authenticationToken backgroundColor
      description foregroundColor labelColor locations logoText
      organizationName passTypeIdentifier serialNumber sharingProhibited
      suppressStripShine voided webServiceURL
    ].each do |key|
      assert json.key?(key), "expected pass.json to include #{key}, keys: #{json.keys.inspect}"
    end
  end

  def test_pass_json_serial_number_matches_pass_record
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)
    assert_equal Passkit::Pass.last.serial_number, json["serialNumber"]
  end

  def test_pass_json_includes_storeCard_block_with_fields
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)
    assert json.key?("storeCard"), "expected storeCard top-level key"
    %w[headerFields primaryFields secondaryFields auxiliaryFields backFields].each do |sub|
      assert json["storeCard"].key?(sub), "expected storeCard to include #{sub}"
    end
  end

  # ------------------------------------------------------------------
  # barcode vs barcodes
  # ------------------------------------------------------------------

  def test_pass_json_uses_barcodes_when_subclass_returns_non_empty
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)
    assert json.key?("barcodes"), "expected pass.json to include barcodes"
    assert_kind_of Array, json["barcodes"]
    refute json.key?("barcode"), "expected pass.json NOT to include barcode when barcodes present"
  end

  def test_pass_json_falls_back_to_barcode_when_barcodes_empty
    path_to_assets = example_pass_path
    klass = make_pass_subclass do
      define_method(:barcodes) { [] }
      define_method(:pass_path) { path_to_assets }
    end

    path = Passkit::Factory.create_pass(klass)
    json = read_pass_json(path)
    assert json.key?("barcode"), "expected pass.json to include barcode when barcodes empty"
    refute json.key?("barcodes"), "expected pass.json NOT to include barcodes when barcodes empty"
  end

  # ------------------------------------------------------------------
  # Optional fields — presence/absence
  # ------------------------------------------------------------------

  def with_subclass(&block)
    path_to_assets = example_pass_path
    klass = make_pass_subclass do
      define_method(:pass_path) { path_to_assets }
      class_eval(&block) if block
    end
    Passkit::Factory.create_pass(klass)
  end

  # appLaunchURL
  def test_pass_json_includes_appLaunchURL_when_set
    path = with_subclass { define_method(:app_launch_url) { "myapp://launch" } }
    json = read_pass_json(path)
    assert_equal "myapp://launch", json["appLaunchURL"]
  end

  def test_pass_json_omits_appLaunchURL_when_nil
    path = with_subclass { define_method(:app_launch_url) { nil } }
    refute read_pass_json(path).key?("appLaunchURL")
  end

  # associatedStoreIdentifiers
  def test_pass_json_includes_associatedStoreIdentifiers_when_set
    path = with_subclass { define_method(:associated_store_identifiers) { [123, 456] } }
    json = read_pass_json(path)
    assert_equal [123, 456], json["associatedStoreIdentifiers"]
  end

  def test_pass_json_omits_associatedStoreIdentifiers_when_empty
    path = with_subclass { define_method(:associated_store_identifiers) { [] } }
    refute read_pass_json(path).key?("associatedStoreIdentifiers")
  end

  # beacons
  def test_pass_json_includes_beacons_when_set
    path = with_subclass { define_method(:beacons) { [{proximityUUID: "abc"}] } }
    json = read_pass_json(path)
    assert_equal [{"proximityUUID" => "abc"}], json["beacons"]
  end

  def test_pass_json_omits_beacons_when_empty
    path = with_subclass { define_method(:beacons) { [] } }
    refute read_pass_json(path).key?("beacons")
  end

  # expirationDate
  def test_pass_json_includes_expirationDate_when_set
    path = with_subclass { define_method(:expiration_date) { "2030-01-01T00:00:00+00:00" } }
    json = read_pass_json(path)
    assert_equal "2030-01-01T00:00:00+00:00", json["expirationDate"]
  end

  def test_pass_json_omits_expirationDate_when_nil
    path = with_subclass { define_method(:expiration_date) { nil } }
    refute read_pass_json(path).key?("expirationDate")
  end

  # groupingIdentifier
  def test_pass_json_includes_groupingIdentifier_when_set
    path = with_subclass { define_method(:grouping_identifier) { "trip-42" } }
    json = read_pass_json(path)
    assert_equal "trip-42", json["groupingIdentifier"]
  end

  def test_pass_json_omits_groupingIdentifier_when_nil
    path = with_subclass { define_method(:grouping_identifier) { nil } }
    refute read_pass_json(path).key?("groupingIdentifier")
  end

  # nfc — Apple requires both `message` and `encryptionPublicKey` when
  # `nfc` is present (validator enforces this).
  def test_pass_json_includes_nfc_when_set
    nfc = {message: "hello", encryptionPublicKey: "BFakePublicKey=="}
    path = with_subclass { define_method(:nfc) { nfc } }
    json = read_pass_json(path)
    assert_equal({"message" => "hello", "encryptionPublicKey" => "BFakePublicKey=="}, json["nfc"])
  end

  def test_pass_json_omits_nfc_when_nil
    path = with_subclass { define_method(:nfc) { nil } }
    refute read_pass_json(path).key?("nfc")
  end

  # relevantDate
  def test_pass_json_includes_relevantDate_when_set
    path = with_subclass { define_method(:relevant_date) { "2026-12-31T12:00:00+00:00" } }
    json = read_pass_json(path)
    assert_equal "2026-12-31T12:00:00+00:00", json["relevantDate"]
  end

  def test_pass_json_omits_relevantDate_when_nil
    path = with_subclass { define_method(:relevant_date) { nil } }
    refute read_pass_json(path).key?("relevantDate")
  end

  # semantics — CurrencyAmount requires both `amount` and `currencyCode`
  # per Apple's spec (validator enforces this).
  def test_pass_json_includes_semantics_when_set
    path = with_subclass { define_method(:semantics) { {balance: {amount: "1", currencyCode: "USD"}} } }
    json = read_pass_json(path)
    assert json["semantics"].is_a?(Hash)
  end

  def test_pass_json_omits_semantics_when_nil
    path = with_subclass { define_method(:semantics) { nil } }
    refute read_pass_json(path).key?("semantics")
  end

  # userInfo
  def test_pass_json_includes_userInfo_when_set
    path = with_subclass { define_method(:user_info) { {favorite: "espresso"} } }
    json = read_pass_json(path)
    assert_equal({"favorite" => "espresso"}, json["userInfo"])
  end

  def test_pass_json_omits_userInfo_when_nil
    path = with_subclass { define_method(:user_info) { nil } }
    refute read_pass_json(path).key?("userInfo")
  end

  # maxDistance
  def test_pass_json_includes_maxDistance_when_set
    path = with_subclass { define_method(:max_distance) { 500 } }
    json = read_pass_json(path)
    assert_equal 500, json["maxDistance"]
  end

  def test_pass_json_omits_maxDistance_when_nil
    path = with_subclass { define_method(:max_distance) { nil } }
    refute read_pass_json(path).key?("maxDistance")
  end

  # ------------------------------------------------------------------
  # boardingPass bug pin
  # ------------------------------------------------------------------

  def test_boarding_pass_merges_extra_fields_into_pass_json
    # Fixed in lib/passkit/generator.rb:109 — the boarding_pass override hash
    # is now merged into the storeCard-shaped block under the :boardingPass
    # key, preserving header/primary/etc fields *and* the transit type.
    path_to_assets = example_pass_path
    klass = make_pass_subclass do
      define_method(:pass_path) { path_to_assets }
      define_method(:pass_type) { :boardingPass }
      define_method(:boarding_pass) { {transitType: "PKTransitTypeGeneric"} }
    end

    path = Passkit::Factory.create_pass(klass)
    json = read_pass_json(path)
    assert json.key?("boardingPass"), "expected boardingPass top-level key"
    assert_equal "PKTransitTypeGeneric", json["boardingPass"]["transitType"]
    assert json["boardingPass"].key?("headerFields"), "expected the field-block keys to survive the merge"
  end

  # ------------------------------------------------------------------
  # Manifest
  # ------------------------------------------------------------------

  def test_manifest_json_hashes_match_sha1_of_each_file
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    manifest = read_manifest(path)
    refute_empty manifest

    Zip::File.open(path) do |zf|
      manifest.each do |fname, declared|
        bytes = zf.read(fname)
        assert_equal Digest::SHA1.hexdigest(bytes), declared,
          "manifest hash mismatch for #{fname}"
      end
    end
  end

  # ------------------------------------------------------------------
  # Dir.glob recursion bug pin
  # ------------------------------------------------------------------

  def test_subdirectory_files_are_included_in_manifest_and_zip
    # Fixed in lib/passkit/generator.rb:118 + :151 — Dir.glob now recurses
    # via "**/*" and skips directory entries. Nested files (e.g. localized
    # .lproj content) make it into both manifest.json and the .pkpass zip,
    # keyed by their path relative to the pass root.
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir["#{example_pass_path}/."], dir)

      nested_dir = File.join(dir, "de.lproj")
      FileUtils.mkdir_p(nested_dir)
      File.write(File.join(nested_dir, "pass.strings"), "\"hello\" = \"hallo\";")

      Passkit::ExampleStoreCard.any_instance.stubs(:pass_path).returns(dir)

      path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)

      manifest = read_manifest(path)
      assert manifest.key?("de.lproj/pass.strings"),
        "expected nested file to be hashed under its relative path; got: #{manifest.keys.inspect}"

      Zip::File.open(path) do |zf|
        names = zf.entries.map(&:name)
        assert_includes names, "de.lproj/pass.strings"
      end
    end
  end

  # ------------------------------------------------------------------
  # sign_manifest
  # ------------------------------------------------------------------

  def test_signature_file_is_non_empty
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    sig_bytes = read_entry(path, "signature")
    assert sig_bytes.bytesize.positive?, "expected signature to be non-empty"
  end

  def test_signature_parses_as_pkcs7_der
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    sig_bytes = read_entry(path, "signature")
    pkcs7 = nil
    assert_nothing_raised = begin
      pkcs7 = OpenSSL::PKCS7.new(sig_bytes)
      true
    rescue => e
      flunk "expected PKCS7 to parse, got: #{e.class}: #{e.message}"
    end
    assert assert_nothing_raised
    assert_kind_of OpenSSL::PKCS7, pkcs7
  end

  def test_signature_includes_signing_certificate
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    sig_bytes = read_entry(path, "signature")
    pkcs7 = OpenSSL::PKCS7.new(sig_bytes)
    assert pkcs7.certificates.any?, "expected at least one cert in PKCS7 signature"
  end

  # ------------------------------------------------------------------
  # compress_passes_files (class method)
  # ------------------------------------------------------------------

  def test_compress_passes_files_zips_inputs
    path1 = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    path2 = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)

    bundle = Passkit::Generator.compress_passes_files([path1, path2])

    assert_kind_of Pathname, bundle
    assert File.exist?(bundle)

    inner_names = Zip::File.open(bundle) { |zf| zf.entries.map(&:name) }
    assert_equal 2, inner_names.size
    assert_includes inner_names, File.basename(path1)
    assert_includes inner_names, File.basename(path2)
    inner_names.each { |n| assert n.end_with?(".pkpass") }
  end

  # ------------------------------------------------------------------
  # clean_ds_store_files
  # ------------------------------------------------------------------

  def test_ds_store_files_are_stripped_from_pkpass
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir["#{example_pass_path}/."], dir)
      File.write(File.join(dir, ".DS_Store"), "junk")

      Passkit::ExampleStoreCard.any_instance.stubs(:pass_path).returns(dir)

      path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
      refute_includes entries(path), ".DS_Store",
        ".DS_Store should be stripped from generated .pkpass"
    end
  end

  # ------------------------------------------------------------------
  # add_other_files hook
  # ------------------------------------------------------------------

  def test_add_other_files_is_called_with_temporary_path
    Passkit::ExampleStoreCard.any_instance.expects(:add_other_files).with(instance_of(Pathname)).at_least_once
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
  end

  # ------------------------------------------------------------------
  # I18n
  # ------------------------------------------------------------------

  def test_generates_with_i18n_locale_from_pass
    path_to_assets = example_pass_path
    klass = make_pass_subclass do
      define_method(:pass_path) { path_to_assets }
      define_method(:language) { :de }
    end

    captured_locale = nil
    original = I18n.method(:with_locale)
    I18n.stubs(:with_locale).with do |locale, *_args|
      captured_locale = locale
      true
    end.yields

    Passkit::Factory.create_pass(klass)

    assert_equal :de, captured_locale
  ensure
    I18n.unstub(:with_locale) if original
  end

  # ------------------------------------------------------------------
  # CERTIFICATE constant bug pin
  # ------------------------------------------------------------------

  def test_certificate_paths_are_resolved_per_call_not_at_class_load
    # Fixed in lib/passkit/generator.rb — the CERTIFICATE / INTERMEDIATE_CERTIFICATE
    # / CERTIFICATE_PASSWORD constants were inlined into #sign_manifest so the
    # gem can be required without those env vars set.
    refute Passkit::Generator.const_defined?(:CERTIFICATE),
      "expected CERTIFICATE constant to be removed (now resolved per-call inside sign_manifest)"
    refute Passkit::Generator.const_defined?(:INTERMEDIATE_CERTIFICATE)
    refute Passkit::Generator.const_defined?(:CERTIFICATE_PASSWORD)
  end

  # ------------------------------------------------------------------
  # Deep signature verification (production hardening)
  # ------------------------------------------------------------------

  def test_signature_verifies_via_pkcs7_verify_against_test_ca
    # Structural parsing is not enough: a future change that broke the math
    # (wrong digest, swapped detached/attached, signing the wrong bytes) would
    # still produce a parseable PKCS7 blob. This pins the *cryptographic*
    # validity against the ephemeral CA.
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pkpass = PkpassHelpers.read_pkpass(path)
    assert PkpassHelpers.verify_pkpass_signature!(pkpass)
  end

  def test_signature_chain_includes_leaf_and_intermediate
    # Apple's PassKit spec requires the signing leaf + intermediate (WWDR) cert
    # to both be embedded in the PKCS7 envelope so iOS Wallet can verify the
    # chain offline. `Generator#sign_manifest` passes [intermediate] as the
    # `certs` arg to PKCS7.sign; the leaf is added automatically.
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pkpass = PkpassHelpers.read_pkpass(path)
    pkcs7 = OpenSSL::PKCS7.new(pkpass[:signature_bytes])

    assert_equal 2, pkcs7.certificates.size,
      "expected leaf + intermediate, got #{pkcs7.certificates.map { |c| c.subject.to_s }.inspect}"

    subjects = pkcs7.certificates.map { |c| c.subject.to_s }
    assert subjects.any? { |s| s.include?("Pass Signing") },
      "expected leaf with subject containing 'Pass Signing', got #{subjects.inspect}"
    assert subjects.any? { |s| s.include?("Intermediate CA") },
      "expected intermediate with subject containing 'Intermediate CA', got #{subjects.inspect}"
  end

  # ------------------------------------------------------------------
  # Manifest hygiene (Apple spec)
  # ------------------------------------------------------------------

  def test_manifest_excludes_manifest_json_itself
    # Per Apple's PassKit spec: manifest.json is the *list of files to verify*
    # and must not list itself. Code-correct because `generate_json_manifest`
    # runs before manifest.json is written — this test pins that invariant.
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    manifest = read_manifest(path)
    refute_includes manifest.keys, "manifest.json",
      "manifest.json must not list itself"
  end

  def test_manifest_excludes_signature
    # `signature` is what verifies manifest.json's integrity; manifest.json
    # cannot reference it (chicken/egg). Code-correct because signing happens
    # after `generate_json_manifest`, but pin it.
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    manifest = read_manifest(path)
    refute_includes manifest.keys, "signature",
      "manifest.json must not list signature"
  end

  def test_manifest_lists_every_zip_entry_except_manifest_and_signature
    # Symmetric check: anything in the .pkpass zip that's neither manifest.json
    # nor signature MUST appear in the manifest (otherwise iOS rejects the pass).
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    zip_entries = entries(path).reject { |n| %w[manifest.json signature].include?(n) }
    manifest_keys = read_manifest(path).keys
    assert_equal zip_entries.sort, manifest_keys.sort,
      "manifest must list every payload file"
  end

  # ------------------------------------------------------------------
  # Localization round-trip (production .lproj scenarios)
  # ------------------------------------------------------------------

  def test_localization_lproj_subdirectory_round_trips_with_relative_path
    # Apple's `pass.strings` localization requires the relative path
    # `<lang>.lproj/pass.strings` to survive both the manifest (so its SHA1 is
    # checked) and the zip (so iOS can find it). This pins the relative-path
    # serialization end-to-end and that the SHA1 in the manifest matches what
    # actually got written.
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir["#{example_pass_path}/."], dir)
      lproj = File.join(dir, "fr.lproj")
      FileUtils.mkdir_p(lproj)
      content = "\"hello\" = \"bonjour\";"
      File.write(File.join(lproj, "pass.strings"), content)

      Passkit::ExampleStoreCard.any_instance.stubs(:pass_path).returns(dir)
      path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)

      manifest = read_manifest(path)
      assert manifest.key?("fr.lproj/pass.strings"),
        "expected fr.lproj/pass.strings in manifest, got #{manifest.keys.inspect}"

      zip_bytes = read_entry(path, "fr.lproj/pass.strings")
      assert_equal content, zip_bytes
      assert_equal Digest::SHA1.hexdigest(content), manifest["fr.lproj/pass.strings"]
    end
  end

  def test_ds_store_files_stripped_from_subdirectories
    # Pin: the `clean_ds_store_files` glob recurses into all subdirectories,
    # not just the top level. macOS hosts that mount the pass folder over
    # SMB/AFS sprinkle these everywhere.
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir["#{example_pass_path}/."], dir)
      File.write(File.join(dir, ".DS_Store"), "junk-top")
      lproj = File.join(dir, "en.lproj")
      FileUtils.mkdir_p(lproj)
      File.write(File.join(lproj, ".DS_Store"), "junk-nested")
      File.write(File.join(lproj, "pass.strings"), "\"x\" = \"y\";")

      Passkit::ExampleStoreCard.any_instance.stubs(:pass_path).returns(dir)
      path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)

      names = entries(path)
      refute names.any? { |n| n.end_with?(".DS_Store") },
        "expected no .DS_Store entries anywhere in zip; got #{names.inspect}"
      assert_includes names, "en.lproj/pass.strings",
        "non-junk localization sibling should still be present"
    end
  end

  # ------------------------------------------------------------------
  # add_other_files hook contributions
  # ------------------------------------------------------------------

  def test_add_other_files_hook_contributions_reach_zip_and_manifest
    # The `add_other_files` hook lets subclasses drop dynamic content (e.g. a
    # generated strip.png) into the temp dir before manifest hashing. Pin
    # that hook output ends up in BOTH the zip and the manifest with a
    # correct SHA1.
    path_to_assets = example_pass_path
    klass = make_pass_subclass do
      define_method(:pass_path) { path_to_assets }
      define_method(:add_other_files) do |tmp_path|
        File.write(File.join(tmp_path, "extra.txt"), "dynamic-content")
      end
    end

    path = Passkit::Factory.create_pass(klass)

    assert_includes entries(path), "extra.txt"
    assert_equal "dynamic-content", read_entry(path, "extra.txt")
    manifest = read_manifest(path)
    assert manifest.key?("extra.txt"), "manifest should hash add_other_files contributions"
    assert_equal Digest::SHA1.hexdigest("dynamic-content"), manifest["extra.txt"]
  end

  # ------------------------------------------------------------------
  # `.pkpasses` bundle: every entry independently valid
  # ------------------------------------------------------------------

  def test_compress_passes_files_produces_independently_valid_pkpass_entries
    # Apple Wallet UA receives a `.pkpasses` zip; each inner `.pkpass` must
    # itself be a complete, signed pass (Wallet processes them independently).
    # This goes beyond the existing structural test by recursively opening
    # every nested entry and PKCS7-verifying its signature.
    path1 = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    path2 = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)

    bundle = Passkit::Generator.compress_passes_files([path1, path2])
    inner_passes = PkpassHelpers.read_pkpasses_bundle(bundle)

    assert_equal 2, inner_passes.size
    inner_passes.each do |pkpass|
      PkpassHelpers::REQUIRED_PKPASS_ENTRIES.each do |required|
        assert_includes pkpass[:entry_names], required,
          "every inner .pkpass must contain #{required}; got #{pkpass[:entry_names].inspect}"
      end
      assert pkpass[:entry_names].any? { |n| n == "icon.png" },
        "every inner .pkpass must contain icon.png"
      assert PkpassHelpers.verify_pkpass_signature!(pkpass),
        "every inner .pkpass signature must verify"
    end
  end

  # ------------------------------------------------------------------
  # pass.json schema (hand-rolled per-field assertions)
  # ------------------------------------------------------------------

  def test_pass_json_passes_full_schema_check_for_storeCard
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)
    assert PkpassHelpers.assert_valid_pass_json(json, pass_type: :storeCard)
  end

  def test_pass_json_passes_full_schema_check_for_eventTicket
    user = User.find(1)
    path = Passkit::Factory.create_pass(Passkit::UserTicket, user)
    json = read_pass_json(path)
    assert PkpassHelpers.assert_valid_pass_json(json, pass_type: :eventTicket)
  end

  def test_pass_json_field_types_are_apple_compliant
    # Sanity-check exact types beyond presence: integers stay integers,
    # booleans stay booleans (no JSON.dump flake), URLs are https.
    path = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    json = read_pass_json(path)

    assert_kind_of Integer, json["formatVersion"]
    assert_equal 1, json["formatVersion"]
    %w[sharingProhibited suppressStripShine voided].each do |k|
      assert_includes [true, false], json[k], "#{k} must be a JSON boolean"
    end
    assert_match(PkpassHelpers::RGB_REGEX, json["foregroundColor"])
    assert_match(PkpassHelpers::RGB_REGEX, json["backgroundColor"])
    assert_match(PkpassHelpers::RGB_REGEX, json["labelColor"])
    assert json["webServiceURL"].start_with?("https://")
    assert_match(/\A[0-9a-f-]{36}\z/, json["serialNumber"])
  end

  def test_pass_json_for_each_supported_pass_type_emits_correct_block
    # The `pass[@pass.pass_type] = {...}` line in Generator means whichever
    # symbol the subclass returns becomes the top-level field-block key.
    # Pin all 5 supported pass_type values produce the corresponding key.
    %i[storeCard coupon eventTicket generic boardingPass].each do |type|
      path_to_assets = example_pass_path
      klass = make_pass_subclass do
        define_method(:pass_path) { path_to_assets }
        define_method(:pass_type) { type }
        define_method(:boarding_pass) { {} } # avoid merge nil
      end
      path = Passkit::Factory.create_pass(klass)
      json = read_pass_json(path)
      assert json.key?(type.to_s),
        "pass_type #{type.inspect} should produce top-level key #{type}; got #{json.keys.inspect}"
      PkpassHelpers::FIELD_BLOCK_SUBKEYS.each do |sub|
        assert json[type.to_s].key?(sub), "pass.json #{type}.#{sub} must be present"
      end
    end
  end

  # ------------------------------------------------------------------
  # iOS 18+ enhanced event ticket fields — include/omit pattern
  # ------------------------------------------------------------------

  def test_pass_json_includes_preferredStyleSchemes_when_set
    path = with_subclass { define_method(:preferred_style_schemes) { ["posterEventTicket"] } }
    assert_equal ["posterEventTicket"], read_pass_json(path)["preferredStyleSchemes"]
  end

  def test_pass_json_omits_preferredStyleSchemes_when_nil
    path = with_subclass { define_method(:preferred_style_schemes) { nil } }
    refute read_pass_json(path).key?("preferredStyleSchemes")
  end

  def test_pass_json_includes_additionalInfoFields_when_non_empty
    fields = [{key: "doors", label: "DOORS", value: "7pm"}]
    path = with_subclass { define_method(:additional_info_fields) { fields } }
    json = read_pass_json(path)
    assert_equal 1, json["additionalInfoFields"].size
    assert_equal "doors", json["additionalInfoFields"][0]["key"]
  end

  def test_pass_json_omits_additionalInfoFields_when_empty
    path = with_subclass { define_method(:additional_info_fields) { [] } }
    refute read_pass_json(path).key?("additionalInfoFields")
  end

  def test_pass_json_includes_eventLogoText_when_set
    path = with_subclass { define_method(:event_logo_text) { "FEST 2026" } }
    assert_equal "FEST 2026", read_pass_json(path)["eventLogoText"]
  end

  def test_pass_json_omits_eventLogoText_when_nil
    path = with_subclass { define_method(:event_logo_text) { nil } }
    refute read_pass_json(path).key?("eventLogoText")
  end

  def test_pass_json_includes_relevantDates_when_non_empty
    dates = [{startDate: "2030-01-01T12:00:00+00:00", endDate: "2030-01-01T15:00:00+00:00"}]
    path = with_subclass { define_method(:relevant_dates) { dates } }
    json = read_pass_json(path)
    assert_equal 1, json["relevantDates"].size
    assert_equal "2030-01-01T12:00:00+00:00", json["relevantDates"][0]["startDate"]
  end

  def test_pass_json_omits_relevantDates_when_empty
    path = with_subclass { define_method(:relevant_dates) { [] } }
    refute read_pass_json(path).key?("relevantDates")
  end

  def test_pass_json_includes_useAutomaticColors_when_true
    path = with_subclass { define_method(:use_automatic_colors) { true } }
    assert_equal true, read_pass_json(path)["useAutomaticColors"]
  end

  def test_pass_json_includes_useAutomaticColors_when_false
    # Distinct from `nil` — `false` is a valid value to write.
    path = with_subclass { define_method(:use_automatic_colors) { false } }
    assert_equal false, read_pass_json(path)["useAutomaticColors"]
  end

  def test_pass_json_omits_useAutomaticColors_when_nil
    path = with_subclass { define_method(:use_automatic_colors) { nil } }
    refute read_pass_json(path).key?("useAutomaticColors")
  end

  def test_pass_json_includes_footerBackgroundColor_when_set
    path = with_subclass { define_method(:footer_background_color) { "rgb(10, 20, 30)" } }
    assert_equal "rgb(10, 20, 30)", read_pass_json(path)["footerBackgroundColor"]
  end

  def test_pass_json_omits_footerBackgroundColor_when_nil
    path = with_subclass { define_method(:footer_background_color) { nil } }
    refute read_pass_json(path).key?("footerBackgroundColor")
  end

  def test_pass_json_includes_auxiliaryStoreIdentifiers_when_non_empty
    path = with_subclass { define_method(:auxiliary_store_identifiers) { [42, 99] } }
    assert_equal [42, 99], read_pass_json(path)["auxiliaryStoreIdentifiers"]
  end

  def test_pass_json_omits_auxiliaryStoreIdentifiers_when_empty
    path = with_subclass { define_method(:auxiliary_store_identifiers) { [] } }
    refute read_pass_json(path).key?("auxiliaryStoreIdentifiers")
  end

  # Venue utility URLs — pinned name+JSON-key mapping for each.
  {
    bag_policy_url: ["bagPolicyURL", "https://example.com/bag"],
    parking_information_url: ["parkingInformationURL", "https://example.com/parking"],
    merchandise_url: ["merchandiseURL", "https://example.com/merch"],
    order_food_url: ["orderFoodURL", "https://example.com/food"],
    transit_information_url: ["transitInformationURL", "https://example.com/transit"],
    directions_information_url: ["directionsInformationURL", "https://example.com/dirs"],
    transfer_url: ["transferURL", "https://example.com/transfer"],
    add_on_url: ["addOnURL", "https://example.com/addon"],
    accessibility_url: ["accessibilityURL", "https://example.com/a11y"],
    purchase_parking_url: ["purchaseParkingURL", "https://example.com/buy-parking"],
    sell_url: ["sellURL", "https://example.com/sell"],
    contact_venue_email: ["contactVenueEmail", "venue@example.com"],
    contact_venue_phone_number: ["contactVenuePhoneNumber", "+15555550100"],
    contact_venue_website: ["contactVenueWebsite", "https://example.com/venue"]
  }.each do |method, (json_key, value)|
    define_method("test_pass_json_includes_#{json_key}_when_set") do
      path = with_subclass { define_method(method) { value } }
      assert_equal value, read_pass_json(path)[json_key]
    end

    define_method("test_pass_json_omits_#{json_key}_when_nil") do
      path = with_subclass { define_method(method) { nil } }
      refute read_pass_json(path).key?(json_key)
    end
  end

  # ------------------------------------------------------------------
  # Validator integration
  # ------------------------------------------------------------------

  def test_generator_invokes_validator_when_config_enabled
    Passkit.configuration.validate_pass_json = true
    err = assert_raises(Passkit::ValidationError) do
      with_subclass { define_method(:foreground_color) { "blue" } }
    end
    assert_match(/foregroundColor must match rgb/, err.message)
  ensure
    Passkit.configuration.validate_pass_json = true
  end

  def test_generator_skips_validator_when_config_disabled
    Passkit.configuration.validate_pass_json = false
    # Bad color shape would otherwise raise; with validation off, generation
    # succeeds and the bad value is written to pass.json verbatim.
    path = with_subclass { define_method(:foreground_color) { "blue" } }
    assert_equal "blue", read_pass_json(path)["foregroundColor"]
  ensure
    Passkit.configuration.validate_pass_json = true
  end

  # ------------------------------------------------------------------
  # Localization integration
  # ------------------------------------------------------------------

  def test_generator_writes_pass_strings_files_into_pkpass
    translations = {en: {"K" => "V"}, es: {"K" => "Valor"}}
    path = with_subclass { define_method(:localized_strings) { translations } }
    pkpass = PkpassHelpers.read_pkpass(path)
    assert_includes pkpass[:entry_names], "en.lproj/pass.strings"
    assert_includes pkpass[:entry_names], "es.lproj/pass.strings"
  end

  def test_generator_skips_lproj_when_localized_strings_empty
    path = with_subclass { define_method(:localized_strings) { {} } }
    pkpass = PkpassHelpers.read_pkpass(path)
    refute pkpass[:entry_names].any? { |n| n.end_with?("pass.strings") }
  end

  def test_pass_strings_files_appear_in_manifest_with_correct_sha1
    path = with_subclass { define_method(:localized_strings) { {en: {"K" => "V"}} } }
    pkpass = PkpassHelpers.read_pkpass(path)
    expected_sha = Digest::SHA1.hexdigest(pkpass[:entry_bytes]["en.lproj/pass.strings"])
    assert_equal expected_sha, pkpass[:manifest]["en.lproj/pass.strings"]
  end
end
