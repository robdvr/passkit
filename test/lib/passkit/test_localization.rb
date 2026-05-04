# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/pkpass_helpers"

class TestLocalization < ActiveSupport::TestCase
  include PkpassHelpers

  def setup
    @tmp = Pathname.new(Dir.mktmpdir("passkit-localization-test"))
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp&.directory?
  end

  # ---- write_strings ----

  def test_write_strings_creates_lproj_directory_per_locale
    Passkit::Localization.write_strings(@tmp, {
      en: {"EVENT" => "Event"},
      es: {"EVENT" => "Evento"}
    })
    assert @tmp.join("en.lproj").directory?
    assert @tmp.join("es.lproj").directory?
    assert @tmp.join("en.lproj/pass.strings").file?
    assert @tmp.join("es.lproj/pass.strings").file?
  end

  def test_write_strings_accepts_string_locale_keys
    Passkit::Localization.write_strings(@tmp, {"en" => {"K" => "V"}})
    assert @tmp.join("en.lproj/pass.strings").file?
  end

  def test_write_strings_emits_apple_pass_strings_format
    Passkit::Localization.write_strings(@tmp, {en: {"EVENT" => "Event", "DOORS" => "Doors"}})
    contents = @tmp.join("en.lproj/pass.strings").read
    assert_includes contents, '"EVENT" = "Event";'
    assert_includes contents, '"DOORS" = "Doors";'
    # Ends with newline.
    assert contents.end_with?("\n")
  end

  def test_write_strings_skips_nil_translations
    assert_nothing_raised { Passkit::Localization.write_strings(@tmp, nil) }
    assert_empty @tmp.children
  end

  def test_write_strings_skips_empty_translations
    Passkit::Localization.write_strings(@tmp, {})
    assert_empty @tmp.children
  end

  def test_write_strings_skips_locale_with_empty_table
    Passkit::Localization.write_strings(@tmp, {en: {}, es: {"K" => "V"}})
    refute @tmp.join("en.lproj").exist?, "expected empty en table to be skipped"
    assert @tmp.join("es.lproj/pass.strings").file?
  end

  def test_write_strings_skips_locale_with_nil_table
    Passkit::Localization.write_strings(@tmp, {en: nil, fr: {"K" => "V"}})
    refute @tmp.join("en.lproj").exist?
    assert @tmp.join("fr.lproj/pass.strings").file?
  end

  def test_write_strings_overwrites_existing_file
    FileUtils.mkdir_p(@tmp.join("en.lproj"))
    File.write(@tmp.join("en.lproj/pass.strings"), "stale content")
    Passkit::Localization.write_strings(@tmp, {en: {"K" => "V"}})
    contents = @tmp.join("en.lproj/pass.strings").read
    refute_includes contents, "stale"
    assert_includes contents, '"K" = "V";'
  end

  # ---- serialize / escape ----

  def test_serialize_escapes_double_quotes_in_value
    out = Passkit::Localization.serialize({"key" => 'say "hi"'})
    assert_includes out, '"key" = "say \"hi\"";'
  end

  def test_serialize_escapes_double_quotes_in_key
    out = Passkit::Localization.serialize({'weird"key' => "v"})
    assert_includes out, '"weird\"key" = "v";'
  end

  def test_serialize_escapes_backslash
    out = Passkit::Localization.serialize({"path" => 'C:\Users'})
    # Source 'C:\Users' is the 8 chars C : \ U s e r s; serialized backslash
    # becomes two backslashes per Apple's .strings escape rules.
    assert_includes out, '"path" = "C:\\\\Users";'
  end

  def test_serialize_escapes_newline_and_carriage_return
    out = Passkit::Localization.serialize({"k" => "line1\nline2\r"})
    assert_includes out, '"k" = "line1\n' + 'line2\r";'
  end

  def test_serialize_handles_symbol_keys_and_values
    out = Passkit::Localization.serialize({event: :Event})
    assert_includes out, '"event" = "Event";'
  end

  def test_serialize_emits_one_entry_per_line
    out = Passkit::Localization.serialize({"a" => "1", "b" => "2"})
    assert_equal 2, out.lines.size
  end

  # ---- end-to-end via Generator ----

  def test_generator_pipeline_writes_localized_strings_into_pkpass
    klass = Class.new(Passkit::BasePass) do
      def folder_name
        "example_store_card"
      end

      def localized_strings
        {en: {"K" => "V"}, fr: {"K" => "Valeur"}}
      end
    end
    Object.const_set("LocalizedTestPass#{SecureRandom.hex(4)}", klass)

    pkpass_path = Passkit::Factory.create_pass(klass)
    pkpass = read_pkpass(pkpass_path)
    assert_includes pkpass[:entry_names], "en.lproj/pass.strings"
    assert_includes pkpass[:entry_names], "fr.lproj/pass.strings"
    assert_includes pkpass[:entry_bytes]["en.lproj/pass.strings"], '"K" = "V";'
    assert_includes pkpass[:entry_bytes]["fr.lproj/pass.strings"], '"K" = "Valeur";'
  end

  def test_generator_pipeline_omits_lproj_when_no_translations
    klass = Class.new(Passkit::BasePass) do
      def folder_name
        "example_store_card"
      end
    end
    Object.const_set("NoLocalizationTestPass#{SecureRandom.hex(4)}", klass)

    pkpass_path = Passkit::Factory.create_pass(klass)
    pkpass = read_pkpass(pkpass_path)
    refute pkpass[:entry_names].any? { |n| n.end_with?("pass.strings") }
  end
end
