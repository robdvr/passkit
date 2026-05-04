module Passkit
  # Generates `<lang>.lproj/pass.strings` files inside a pass directory so
  # subclasses can declare translations without hand-writing the file format.
  #
  # The Generator copies `.lproj/` subdirectories recursively (already), so
  # files written here are picked up by the manifest hash and end up in the
  # signed `.pkpass` automatically.
  #
  # Apple's `pass.strings` format:
  #
  #   "key" = "value";
  #   "another key" = "another value";
  #
  # Per Apple's spec the encoding is UTF-16 LE; modern Wallet also accepts
  # UTF-8 without BOM, which is what we write (smaller files, easier to
  # diff). If Wallet ever rejects a localized pass, switching encodings is
  # isolated to this module.
  module Localization
    module_function

    # Writes `<locale>.lproj/pass.strings` for each locale in `translations`.
    # `translations` shape:
    #   { en: { "EVENT" => "Event" }, "es" => { "EVENT" => "Evento" } }
    # Locale keys may be strings or symbols. A locale with an empty/nil hash
    # is skipped (no empty .lproj directory created).
    def write_strings(pass_path, translations)
      return if translations.nil? || translations.empty?

      translations.each do |locale, table|
        next if table.nil? || table.empty?

        lproj = Pathname.new(pass_path).join("#{locale}.lproj")
        FileUtils.mkdir_p(lproj)
        File.write(lproj.join("pass.strings"), serialize(table))
      end
    end

    # Serialize a flat string=>string table to Apple's pass.strings format.
    # Backslashes and double quotes in keys/values are escaped per Apple's
    # convention; embedded newlines become `\n`.
    def serialize(table)
      lines = table.map do |key, value|
        %("#{escape(key.to_s)}" = "#{escape(value.to_s)}";)
      end
      lines.join("\n") + "\n"
    end

    def escape(str)
      str.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", '\\n').gsub("\r", '\\r')
    end
  end
end
