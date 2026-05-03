## [Unreleased]

### Breaking changes
- **Rails / Ruby floor raised.** Now requires Rails ≥ 8.0 and Ruby ≥ 3.4. The dummy app and tests run against Rails 8.1.3 / Ruby 3.4.x.
- **URL payload format changed.** `Passkit::UrlEncrypt` now uses AES-256-GCM (authenticated encryption) with a per-encrypt random 12-byte IV and a SHA-256 derived key, prefixed with a `02` format-version byte. Previously-issued pass URLs (in user wallets, in already-sent emails) will no longer decrypt — re-issue them after upgrading. GCM rejects any tampered ciphertext or auth tag with `OpenSSL::Cipher::CipherError`.
- **`serial_number` collision retry loop removed.** A new migration adds a unique DB index on `passkit_passes.serial_number`; the `before_validation` callback no longer polls `Passkit::Pass.exists?`. Existing installs need to run the new migration: `rails g passkit:install` will copy it, or write your own with `add_index :passkit_passes, :serial_number, unique: true`.
- **Asset pipeline.** Dummy app and dev deps switched from `sprockets-rails` to `propshaft` to match Rails 8 defaults. The gem itself ships no assets, so host apps keep their own pipeline choice.

### Bug fixes
- **`Passkit::Generator`** — `Dir.glob(temp.join("**"))` was shallow, silently dropping localized `.lproj` files and any other nested assets from `manifest.json` and the final `.pkpass` zip. Now uses `**/*` and skips directories. Manifest keys for nested files are the path relative to the pass root.
- **`Passkit::Generator#generate_json_pass`** — boarding-pass `transitType` (and any other `boarding_pass` overrides) were silently dropped because `pass[:boardingPass].merge(...)` returned a new hash that was discarded. Boarding-pass extras are now properly merged.
- **`Passkit::Generator`** — `CERTIFICATE`, `INTERMEDIATE_CERTIFICATE`, and `CERTIFICATE_PASSWORD` constants were resolved at class load, breaking `require "passkit"` in environments without the certificate env vars. Now resolved per call inside `#sign_manifest`.
- **`Passkit::Generator`** — `File.read` and `File.open(path, "w")` could mangle binary assets (PNG icons, signatures, zip contents) on non-Linux platforms. Now uses `File.binread` / `File.binwrite` / `"wb"` consistently.
- **`Api::V1::PassesController#decrypt_payload`** — wraps `DateTime.parse(@payload[:valid_until])` in a rescue. A nil or malformed `valid_until` now returns 404 instead of 500.
- **`Api::V1::PassesController#decrypt_payload`** — rescues `OpenSSL::Cipher::CipherError` and `JSON::ParserError` from `UrlEncrypt.decrypt` so tampered or malformed URLs return 404 instead of leaking a 500 stacktrace that confirms a crypto error.
- **`Api::V1::PassesController#show`** — rescues `Time.zone.parse` for malformed `If-Modified-Since` headers; treats them as not-present (response is the regenerated `.pkpass`) instead of 500.
- **`Api::V1::PassesController#create`** — `collection_name` from the payload is validated against `generator.class.reflect_on_association(name)` before calling `public_send`. Unknown methods return 404 — closes a defense-in-depth gap if the encryption key is ever leaked.

### New configuration
- `Passkit.configuration.pass_classes` — optional allowlist of pass class names (strings or constants). Empty default = no allowlist enforcement (backward compatible). When populated, payloads referencing other classes 404 before `constantize`.
- `Passkit.configuration.pass_generators` — same idea for `generator_class` (the polymorphic AR model that owns the pass).
- **`Api::V1::RegistrationsController#destroy`** — was matching by `passkit_device_id` (DB integer FK) when Apple sends `deviceLibraryIdentifier` (an opaque string). Real Apple Wallet unregistrations were silently no-ops. Now looks up `Device` by `identifier` to match the rest of the controller.
- **`Api::V1::RegistrationsController#register_device`** — `find_or_create_by!` block only ran on create, so push-token rotation by Apple was silently dropped on subsequent registrations. Now updates `push_token` post-create when it differs.
- **`Api::V1::RegistrationsController#push_token`** — replaced raw-body `JSON.parse` with `params[:pushToken]`, with a body-parse fallback that rescues `JSON::ParserError`. Empty / non-JSON bodies no longer crash the registration endpoint.
- **`Api::V1::RegistrationsController#fetch_registered_passes`** — `passesUpdatedSince` filter no longer loads every pass into memory; uses a SQL `WHERE updated_at >= ?` filter and rescues malformed input dates.
- **`Api::V1::RegistrationsController#show`** — dropped a redundant `.to_json` from `render json:`.
- **`Api::V1::LogsController#create`** — wraps `params[:logs]` in `Array(...)` so a missing/empty body is a no-op 200 instead of a 500.
- **`Dashboard::PreviewsController#show`** — unknown `class_name` returns 404 instead of crashing on `nil.call`.
- **`Passkit::BasePass#format_version`** — was returning a String when `PASSKIT_FORMAT_VERSION` env was set, producing a JSON string in `pass.json` and failing Apple's pass validation. Now coerces to Integer.
- **Dead code removed** — the `authentication_token` method in `RegistrationsController` that always returned `""`.

### New
- Test suite expanded from 8 to 207 tests (500 assertions). Coverage: 92% line, 97% branch.
- `test/support/cert_helper.rb` generates ephemeral throwaway p12 + intermediate certs at suite start so `Passkit::Generator#sign_manifest` is exercised under test.
- GitHub Actions CI workflow (`test`, `lint`).

## [0.7.0]
- [#25](https://github.com/coorasse/passkit/pull/25): Change the label default color to black.

## [0.6.1]

- [#21](https://github.com/coorasse/passkit/pull/21): Support an ecryption key via `PASSKIT_URL_ENCRYPTION_KEY` environment variable.

## [0.6.0]

- [#20](https://github.com/coorasse/passkit/pull/20): Many new attributes added.

## [0.5.4]

- Fix last-modified header format. Return it in RFC 2616 format.

## [0.5.3]

- [#15](https://github.com/coorasse/passkit/pull/15): Send correct headers also on passes_controller


## [0.5.2]

- [#14](https://github.com/coorasse/passkit/pull/14): Send correct headers with previews so it auto-adds on iOS

## [0.5.1]

- [#13](https://github.com/coorasse/passkit/pull/13): Added sharingProhibited 
- [#13](https://github.com/coorasse/passkit/pull/13): Added maxDistance
- [#13](https://github.com/coorasse/passkit/pull/13): Allow custom files with add_other_files

## [0.5.0]

- Allow configuring labelColor
- Allow receiving the same push otken with different device identifiers
- Make the last_update more flexible

## [0.4.2]

- Fix the unregister endpoint.

## [0.4.1]

- Allow the registration of two passes on the same device.

## [0.4.0]

- Allow to use the dashboard also in production.
- Allow to protect the dashboard using different strategies. Basic auth is default.
- Breaking: now your Passkit dashboard is mounted under `/passkit/dashboard` instead of just `/passkit`. 

## [0.3.3]

- Fix previews page.

## [0.3.2]

## [0.3.1]

## [0.3.0]

## [0.2.0]

## [0.1.0]

- Initial release.
