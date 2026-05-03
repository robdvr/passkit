# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this gem is

`passkit` is a mountable Rails engine that generates, signs, and serves Apple Wallet `.pkpass` files (and exposes them to Android via walletpasses.io). It ships ActiveRecord models, the Apple PassKit Web Service API endpoints, a small admin dashboard, and a `Passkit::BasePass` superclass that host apps subclass to define their own passes.

## Common commands

Setup / install deps:

```sh
bin/setup            # bundle install
```

Tests (Minitest, run against the dummy Rails app under `test/dummy`):

```sh
bundle exec rake test                           # full suite
bundle exec ruby -Ilib -Itest test/api/v1/test_passes_controller.rb   # one file
bundle exec ruby -Ilib -Itest test/api/v1/test_passes_controller.rb -n /create/   # filter
```

Lint (Standard Ruby — `default` rake task runs both):

```sh
bundle exec standardrb
bundle exec standardrb --fix
bundle exec rake             # test + standard
```

Console / release:

```sh
bin/console
bundle exec rake install
bundle exec rake release     # tags, pushes, publishes to rubygems
```

`.env` is loaded automatically by `dotenv` in both `test_helper.rb` and `rails_helper.rb`. Copy `.example.env` → `.env` before running anything that boots the configuration (the `Passkit::Configuration` constructor raises if any required env var is missing — see `lib/passkit.rb`).

## Architecture

### Engine layout

The gem is a `Rails::Engine` with `isolate_namespace Passkit` (`lib/passkit/engine.rb`). Host apps mount it under `/passkit`; routes split into two namespaces (`config/routes.rb`):

- `/passkit/api/v1/...` — the Apple PassKit Web Service endpoints (`Passkit::Api::V1::PassesController`, `RegistrationsController`, `LogsController`). These speak Apple's pass-distribution protocol; the matching client is iOS Wallet itself, so the request/response shapes are dictated by Apple's spec, not by us.
- `/passkit/dashboard/...` — `previews`, `passes`, `logs`. Protected by `Passkit.configuration.authenticate_dashboard_with`, which defaults to HTTP basic auth using `PASSKIT_DASHBOARD_USERNAME` / `PASSKIT_DASHBOARD_PASSWORD` but can be replaced with a Devise/Warden block in the host's `config/passkit.rb` initializer.

Autoloading uses Zeitwerk-for-gem (`Zeitwerk::Loader.for_gem`) with `lib/generators` ignored, so anything in `lib/passkit/` and `app/**/passkit/` is autoloaded by namespace.

### How a pass becomes a `.pkpass`

The pipeline is the load-bearing part of this codebase. Following one request end-to-end is the fastest way to understand the gem:

1. **URL generation (host app).** `Passkit::UrlGenerator.new(MyPass, owner, :collection?)` builds an iOS download URL pointing at `passes/:payload`. The payload is built by `PayloadGenerator.hash` (`{pass_class, generator_class, generator_id, collection_name, valid_until: 30.days.from_now}`) and AES-128-CBC encrypted by `UrlEncrypt` using `PASSKIT_URL_ENCRYPTION_KEY` (or the host's `secret_key_base[0..15]` as fallback). `.android` wraps the same URL with `https://walletpass.io?u=`.
2. **Pass creation (`Api::V1::PassesController#create`).** `decrypt_payload` recovers the hash, rejects expired payloads, and `set_generator` reconstitutes the AR record. If `collection_name` is set, the controller iterates `generator.public_send(collection_name)` and bundles the results as a `.pkpasses` archive; otherwise it produces a single `.pkpass`.
3. **`Passkit::Factory.create_pass`** persists a `Passkit::Pass` row (which generates a `serial_number` and `authentication_token` in a `before_validation`) and hands it to `Passkit::Generator`.
4. **`Passkit::Generator#generate_and_sign`** is the core builder. It copies the pass's image folder into `Rails.root/tmp/passkit/<file_name>/`, calls `add_other_files(path)` so the subclass can drop in dynamic images, builds `pass.json` from the subclass's overrides, computes `manifest.json` (SHA1 of every file), signs it with `OpenSSL::PKCS7.sign` using the p12 + Apple WWDR intermediate cert, and `rubyzip`s the directory into a `.pkpass`. Returned path is what `send_file` ships back.
5. **Updates.** `PassesController#show` and `RegistrationsController` implement Apple's auth-token-protected web service so iOS can poll for changes. `last-modified` headers come from `Pass#last_update` (delegates to the subclass's `last_update`, falling back to the row's `updated_at`).

### `BasePass` is the extension point

`lib/passkit/base_pass.rb` defines every field Apple's pass.json supports as an overridable instance method (colors, locations, barcode(s), header/primary/secondary/auxiliary/back fields, NFC, semantics, beacons, boarding-pass info, expiration/relevant dates, etc.). Subclasses live in the host app or the gem (see `Passkit::ExampleStoreCard`). Two conventions matter:

- `pass_path` resolves to `Rails.root/private/passkit/<class.demodulize.underscore>/` if it exists, else falls back to the gem's own folder. **`icon.png` is required** — `Generator#check_necessary_files` raises otherwise.
- `Passkit::Pass` `delegate`s ~30 methods to `instance` (the subclass), so the AR record acts as a façade over the subclass during generation. When you add a new pass field, both `BasePass` (default) and `Pass` (delegate list) need to know about it, and `Generator#generate_json_pass` is what writes it into pass.json.

### Models

- `Passkit::Pass` (`passkit_passes`) — one row per generated pass. Polymorphic `belongs_to :generator` (the host app's record, e.g. a `User` or `Ticket`), `klass` column stores the pass subclass name, `has_many :devices, through: :registrations`.
- `Passkit::Device` (`passkit_devices`) — iOS device identifier + APNs `push_token`.
- `Passkit::Registration` — join table between passes and devices, written by the Apple registration endpoint.
- `Passkit::Log` — captures the JSON Apple posts to the `log` endpoint when something fails on-device. The dashboard renders these.

Migrations are not in `db/migrate/` of the engine; they're generated into the host app via `rails g passkit:install` (see `lib/generators/passkit/install_generator.rb` + `lib/generators/templates/create_passkit_tables.rb.tt`), which also drops `config/initializers/passkit.rb`.

### Test layout

`test/dummy/` is a minimal Rails app whose `config/environment` is what `test/rails_helper.rb` boots. Engine migrations are merged in via `ActiveRecord::Migrator.migrations_paths << "../db/migrate"`. API tests live under `test/api/v1/`, system tests under `test/system/`. The dummy app's own tests in `test/dummy/test/` are not part of the engine's suite.

## Required environment variables

The `Passkit::Configuration` initializer **raises** unless all of these are set, so any code path that loads `Passkit.configure` (including the test boot) needs them:

- `PASSKIT_WEB_SERVICE_HOST` (must start with `https://`)
- `PASSKIT_CERTIFICATE_KEY`, `PASSKIT_PRIVATE_P12_CERTIFICATE`, `PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE` — signing material
- `PASSKIT_APPLE_TEAM_IDENTIFIER`, `PASSKIT_PASS_TYPE_IDENTIFIER`
- Optional: `PASSKIT_URL_ENCRYPTION_KEY` (else `secret_key_base[0..15]`), `PASSKIT_FORMAT_VERSION`, `PASSKIT_DASHBOARD_USERNAME` / `PASSKIT_DASHBOARD_PASSWORD`

`docs/passkit_environment_variables.md` walks through obtaining the Apple certs.
