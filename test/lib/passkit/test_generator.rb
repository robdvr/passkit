# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"
require "zip"
require "json"
require "digest"
require "fileutils"
require "tmpdir"

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

  # nfc
  def test_pass_json_includes_nfc_when_set
    path = with_subclass { define_method(:nfc) { {message: "hello"} } }
    json = read_pass_json(path)
    assert_equal({"message" => "hello"}, json["nfc"])
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

  # semantics
  def test_pass_json_includes_semantics_when_set
    path = with_subclass { define_method(:semantics) { {balance: {amount: "1"}} } }
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
end
