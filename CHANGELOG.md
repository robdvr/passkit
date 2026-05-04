## [Unreleased]

### Breaking changes
- **Rails / Ruby floor raised.** Now requires Rails ≥ 8.0 and Ruby ≥ 3.4. The dummy app and tests run against Rails 8.1.3 / Ruby 3.4.x.
- **URL payload format changed.** `Passkit::UrlEncrypt` now uses AES-256-GCM (authenticated encryption) with a per-encrypt random 12-byte IV and a SHA-256 derived key, prefixed with a `02` format-version byte. Previously-issued pass URLs (in user wallets, in already-sent emails) will no longer decrypt — re-issue them after upgrading. GCM rejects any tampered ciphertext or auth tag with `OpenSSL::Cipher::CipherError`.
- **`serial_number` collision retry loop removed.** A new migration adds a unique DB index on `passkit_passes.serial_number`; the `before_validation` callback no longer polls `Passkit::Pass.exists?`. Existing installs need to run the new migration: `rails g passkit:install` will copy it, or write your own with `add_index :passkit_passes, :serial_number, unique: true`.
- **Asset pipeline.** Dummy app and dev deps switched from `sprockets-rails` to `propshaft` to match Rails 8 defaults. The gem itself ships no assets, so host apps keep their own pipeline choice.
- **`UrlGenerator#android` no longer wraps with walletpasses.io.** `#android` is now an alias for `#ios` — both return the raw `.pkpass` URL. Android opens it with whichever installed app handles `application/vnd.apple.pkpass` (Google Wallet, PassWallet, etc.). The `WALLET_PASS_PREFIX` constant has been removed. Hosts that relied on the redirect should either accept the new direct-download behavior or wrap the URL themselves.

### Bug fixes
- **`Passkit::Generator#generate_json_pass`** — `locations` and `logoText` were emitted unconditionally as `[]` / `null` when the host pass returned an empty array or nil. Apple's PassKit spec marks both as optional (omit-when-empty); strict iOS Wallet versions reject passes containing `"locations": []` or `"logoText": null` and the install silently fails on iPhone with no user-visible error. Pass Viewer on macOS is more permissive and accepts both, so the bug only surfaces on real devices. Now omitted from the JSON when empty.
- **`Api::V1::RegistrationsController#fetch_registered_passes`** — `passesUpdatedSince` was parsed with `Date.parse`, which silently rounded the timestamp to midnight and expanded the update window by up to 24h (passes Apple should not have re-fetched were returned as updatable). Now uses `Time.zone.parse`, which preserves H:M:S. Transparent to host apps.
- **`Api::V1::RegistrationsController#updatable_passes`** — `lastUpdated` was a `Time` instance, whose JSON serialization is Ruby-specific and does not round-trip cleanly through `Time.zone.parse` on the next request. Now an ISO 8601 String.
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
- `Passkit.configuration.validate_pass_json` — boolean, default `true`. When enabled, `Passkit::Validator` runs the generated `pass.json` hash through a full schema check before signing, raising `Passkit::ValidationError` on bad shapes. Set to `false` as a temporary escape hatch if the validator rejects something Apple actually accepts; please file an issue alongside.
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
- **iOS 18+ Enhanced Event Ticket support.** New overridable methods on `Passkit::BasePass` (and matching `Passkit::Pass` delegates) for the poster-style event layout: `preferred_style_schemes`, `additional_info_fields`, `event_logo_text`, `relevant_dates` (plural — supersedes singular `relevant_date` on iOS 18+), `use_automatic_colors`, `footer_background_color`, `auxiliary_store_identifiers`. All default to `nil`/`[]` so existing subclasses are unaffected; subclasses opt in by overriding. iOS ≤17 ignores these keys and renders the legacy layout, so populating both classic field arrays and the new keys gives backwards-compatible passes.
- **Venue utility URLs (iOS 18+).** New BasePass overrides surface as tappable rows in the enhanced ticket detail view: `bag_policy_url`, `parking_information_url`, `merchandise_url`, `order_food_url`, `transit_information_url`, `directions_information_url`, `transfer_url`, `add_on_url`, `accessibility_url`, `purchase_parking_url`, `sell_url`, `contact_venue_email`, `contact_venue_phone_number`, `contact_venue_website`.
- **`Passkit::Validator`** — schema validation of `pass.json` at generation time. Catches typos, bad enum values, malformed sub-objects, missing required keys, color regex violations, ISO 8601 errors, and out-of-range `relevantDates` windows before Apple does. Validates known semantic sub-object shapes (Seat, Location, CurrencyAmount, PersonNameComponents, EventDateInfo, WifiNetwork) and per-field semantics, but allows unknown semantic keys to pass through (Apple adds new ones every iOS cycle). Opt out with `Passkit.configuration.validate_pass_json = false`.
- **`Passkit::Localization.write_strings(path, translations)`** — generator helper that writes Apple's `<lang>.lproj/pass.strings` files inside the temporary pass directory. Pairs with the existing `BasePass#language` override and `Generator`'s `I18n.with_locale` block. Encoding is UTF-8 (modern Wallet accepts it; switching to UTF-16 LE is isolated to this module if needed).
- **`Passkit::BasePass#localized_strings`** — declarative translations consumed by `Passkit::Localization`. Returns `{ en: { "EVENT" => "Event" }, es: { "EVENT" => "Evento" } }`-shaped hash. Wallet substitutes field `value`s matching a key at render time per the device language.
- **`Passkit::UserTicket` example upgraded** to demonstrate the iOS 18+ enhanced layout end-to-end: `preferredStyleSchemes`, `eventLogoText`, expanded semantics (`venueEntrance`, `admissionLevel`, `attendeeName`, `venueDoorsOpenDate`, `genre`), three venue utility URLs, and English + Spanish localized strings. Both legacy and enhanced fields are populated, so the same example renders correctly on iOS ≤17 and iOS 18+.
- Test suite expanded from 269 to 451 tests (1000 assertions). New coverage: validator (94 tests across required keys, enums, sub-object schemas, multi-error aggregation), localization (16 tests including end-to-end manifest+zip integration), iOS 18+ Generator field writes (35 tests for include/omit semantics on each new key), `Date.parse` regression (2 tests), enhanced eventTicket schema check in `assert_valid_pass_json`.
- `test/support/cert_helper.rb` generates ephemeral throwaway p12 + intermediate certs at suite start so `Passkit::Generator#sign_manifest` is exercised under test.
- `test/support/pkpass_helpers.rb` exposes `read_pkpass`, `read_pkpasses_bundle`, `verify_pkpass_signature!`, and `assert_valid_pass_json` so generator, controller, and integration tests share one source of truth for `.pkpass` introspection and PKCS7 verification against the test CA.
- Production-hardening tests added on top of the structural baseline:
  - **PKCS7 mathematical verification** — every generated `.pkpass` is now verified end-to-end via `OpenSSL::PKCS7#verify` against an in-memory `X509::Store` populated with the test CA, in addition to structural parsing. Catches signing-math regressions that produce a parseable-but-invalid signature.
  - **Manifest hygiene** — pinned that `manifest.json` excludes both itself and `signature`, and lists every other zip entry (Apple PassKit spec).
  - **Localization round-trip** — `<lang>.lproj/<file>` survives copy + manifest hashing + zip with the correct relative path and a SHA-1 that matches the actual bytes.
  - **`.pkpasses` bundle integrity** — every nested `.pkpass` inside an Apple-Wallet-bound bundle is independently parsed, schema-checked, and signature-verified.
  - **Android lifecycle integration test** — `UrlGenerator#android == #ios` confirmed end-to-end: Chrome-on-Android UA receives the HTML index, the click-through link returns a single signed `.pkpass` with a verifying PKCS7 signature.
  - **`If-Modified-Since` boundary** — equal-to-`last_update` returns 304, `last_update − 1s` and far-past return 200 (pinning the strict `>` comparator that prevents iOS from re-downloading on every poll).
  - **Auth header parser pin** — documented (without changing) that `request.headers["Authorization"]&.split(" ")&.last` accepts any scheme prefix as long as the trailing token matches a stored `authentication_token`. Real Apple Wallet always sends `ApplePass <hex>`; tightening would be a backwards-incompatible change.
  - **Cross-pass token reuse** — pass A's token cannot authenticate pass B (the `find_by(serial_number:, authentication_token:)` AND-guard).
  - **User-Agent edge cases** — missing / empty / lowercase UAs and Apple Watch's `Wallet/8.0 watchOS/10.0` form are all classified correctly.
  - **`valid_until` boundary** — uses `travel_to` (no wall-clock dependence): 1s past returns 404, 1s future returns 200.
  - **`passesUpdatedSince` SQL filter** — verified via `ActiveSupport::Notifications` that the cutoff pushes a `WHERE updated_at >= ?` into SQL rather than loading every pass into memory.
  - **Push-token rotation hygiene** — explicit `null` and blank `""` push tokens never overwrite a previously-stored APNs token.
  - **`pass.json` schema** — hand-rolled per-field assertions (no new gem dependency) covering required keys, types, `rgb(r,g,b)` regex, ISO 8601 dates, `https://` web service URL, and the field-block emission for all 5 supported `pass_type` values (`storeCard`, `coupon`, `eventTicket`, `generic`, `boardingPass`).
  - **`URL Encrypt` boundary + tampering** — exact-minimum length, below-minimum, non-`String` input, and parameterized corruption of each region (IV / auth tag / ciphertext) all raise `OpenSSL::Cipher::CipherError`.
  - **Configuration hygiene** — empty-string `PASSKIT_WEB_SERVICE_HOST` raises (via the `https://` start-with check); default empty allowlists are pinned for backward compatibility; `pass_classes` / `pass_generators` setters round-trip.
- GitHub Actions CI workflow (`test`, `lint`).

### Upgrade guide
The new tests are additive and do not change runtime behavior. **No migration or configuration change is required.** Host apps already running on the [Unreleased] line need only `bundle update passkit` to pick up the expanded suite.

iOS 18+ enhanced event ticket fields are opt-in (defaults are `nil`/`[]`), so existing pass subclasses are unaffected. The new `Passkit::Validator` is on by default and runs before signing; if a subclass currently emits `pass.json` shapes Apple accepts but the validator rejects, set `Passkit.configuration.validate_pass_json = false` as a temporary escape hatch and file an issue describing the rejected shape so the validator can be loosened.

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
