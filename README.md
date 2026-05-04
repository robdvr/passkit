# <img src="./docs/wallet.png" alt="Goboony" height="50"/> Passkit

`passkit` is a Ruby gem (mountable Rails engine) for generating, signing, and serving `.pkpass` Wallet Passes from a single pipeline.

## How cross-platform support actually works

The same signed `.pkpass` file URL is served to every client. What happens next depends on the device:

* **iOS** — Apple Wallet opens the file natively. Full PassKit Web Service integration: registration, per-device update polling, `Last-Modified`-based 304s.
* **Android** — the device receives `application/vnd.apple.pkpass` and offers it to whichever installed app handles that MIME type. **Google Wallet does *not* natively read `.pkpass`** — users without a third-party reader (PassWallet, etc.) will see a "no app to open" dialog. There is no registration or update protocol on Android; the user gets the file once, and that's it.
* **Bundles (`.pkpasses`)** — when `collection_name` is set on a URL, the controller branches on User-Agent. Apple Wallet UAs (`PassKit/*`, `Wallet/*`) get the spec `.pkpasses` zip. Browsers and Android clients get an HTML index instead, with one download link per pass — because no Android reader understands `.pkpasses`.

**Do not** advertise this gem as "native Google Wallet" — it isn't. If you need first-class Android Wallet UX, you need a parallel Google Wallet API integration (JWT-signed event-ticket / generic-pass class objects), which this gem does not provide.

Do you have a QRCode or a Barcode anywhere in your app that you want to distribute as a Wallet Pass? Look no further!

**We provide:**

* A (not yet) fancy dashboard to manage your passes, registered devices and logs.
* All API endpoints to serve your passes: create, register, update, unregister, etc...
* All necessary ActiveRecord models.
* A BasePass model that you can extend to create your own passes.
* Some helpers to generate the necessary URLs, so that you can include them in the emails.
* Examples for everything.

**We don't provide (yet):**

* A fancy dashboard: our dashboard is really really simple right now. Pull requests are welcome!
* Push notifications: APNs is not implemented. `push_token` is captured by the registration endpoint but never used to send updates. Pull requests are welcome!
* Native Google Wallet API integration: see "How cross-platform support actually works" above.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'passkit'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install passkit

Run the initializer:

    $ rails g passkit:install

that will generate the migrations and the initializer file.

Mount the engine in your `config/routes.rb`:

```ruby
mount Passkit::Engine => '/passkit', as: 'passkit'
```

and run `bin/rails db:migrate`.

### Setup environment variables

If you followed the installation steps, you already saw that Passkit provides
you the tables and ActiveRecord models, and also an engine with the necessary APIs already implemented.

Now is your turn. Before proceeding, you need to set these ENV variables:
* `PASSKIT_WEB_SERVICE_HOST`
* `PASSKIT_CERTIFICATE_KEY`
* `PASSKIT_PRIVATE_P12_CERTIFICATE`
* `PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE`
* `PASSKIT_APPLE_TEAM_IDENTIFIER`
* `PASSKIT_PASS_TYPE_IDENTIFIER`

We have a [specific guide on how to get all these](docs/passkit_environment_variables.md), please follow it.
You cannot start using this library without these variables set, and we cannot do the work for you.

## Quick start

Once the engine is mounted, the migrations are run, and the env vars are set, the bundled `ExampleStoreCard` is wired up end-to-end. To verify your setup:

1. Boot the host app: `bin/rails server`.
2. Open `http://localhost:3000/passkit/dashboard/previews` (basic-auth credentials from `PASSKIT_DASHBOARD_USERNAME` / `PASSKIT_DASHBOARD_PASSWORD`).
3. Click the download button next to `ExampleStoreCard`. You'll get a signed `.pkpass`.
4. On macOS, double-click the file to open it in Pass Viewer; on iPhone, AirDrop it and Wallet will offer to install it.

If Pass Viewer or Wallet refuses the file, the most common cause is a cert mismatch between `PASSKIT_PASS_TYPE_IDENTIFIER` and the pass-signing certificate. See [Debug issues](#debug-issues) below.

## Configuration

Drop a `config/initializers/passkit.rb` (the install generator creates one for you) and customize behavior with `Passkit.configure`:

```ruby
Passkit.configure do |config|
  # Optional defense-in-depth: only allow these pass classes to be served
  # via the encrypted-payload endpoint. The payload's pass_class is matched
  # against this list before `constantize` is called, so an attacker cannot
  # coerce the controller into instantiating arbitrary Ruby classes.
  # Empty array (default) means no allowlist enforcement.
  config.pass_classes    = ["MyApp::LoyaltyCard", "MyApp::EventTicket"]
  config.pass_generators = ["User", "Ticket"]

  # Replace the default HTTP basic auth on the dashboard with whatever
  # the host app uses (Devise / Warden shown). Block runs in the
  # dashboard controller's instance context.
  config.authenticate_dashboard_with do
    warden.authenticate! scope: :user
    # redirect_to main_app.root_path unless warden.user.admin?
  end
end
```

Strongly recommended: set `pass_classes` and `pass_generators` in production. With them empty, any class name in the (encrypted) payload will be `constantize`d — fine if your URL encryption key is not leaked, but the allowlist is cheap belt-and-suspenders.

## Usage

### Dashboard

`http://localhost:3000/passkit/dashboard/previews` lists every pass class registered in `Passkit.configuration.available_passes` and offers a download for each. The dashboard also exposes:

* `/passkit/dashboard/passes` — every `Passkit::Pass` row that's been generated, with serial number and the device(s) that registered for updates.
* `/passkit/dashboard/logs` — the JSON Apple Wallet POSTs to `/passkit/api/v1/log` when something fails on-device. Invaluable for debugging signing or pass.json issues.

### Create your own Wallet Pass

Subclass `Passkit::BasePass` and override the fields you care about. The class name (demodulized + underscored) determines the image folder: `MyApp::EventPass` looks under `private/passkit/event_pass/`. The only image the gem strictly requires is `icon.png` — provide `icon@2x.png` / `icon@3x.png` and `logo.png` / `logo@2x.png` for proper rendering on retina screens.

A minimal worked example (eventTicket — assumes a `Ticket` AR record with `event_name`, `starts_at`, `seat`, and `qr_token` columns):

```ruby
# app/lib/my_app/event_pass.rb
module MyApp
  class EventPass < Passkit::BasePass
    def pass_type        = :eventTicket
    def organization_name = "Acme Events"
    def description       = "Ticket for #{@generator.event_name}"
    def logo_text         = @generator.event_name

    # The polymorphic generator AR record passed to Factory.create_pass.
    # Available as @generator inside any field method.
    def primary_fields
      [{key: "event", label: "EVENT", value: @generator.event_name}]
    end

    def secondary_fields
      [
        {key: "doors", label: "DOORS",
         value: @generator.starts_at.iso8601,
         dateStyle: "PKDateStyleNone", timeStyle: "PKDateStyleShort"},
        {key: "seat",  label: "SEAT",  value: @generator.seat}
      ]
    end

    def back_fields
      [{key: "tos", label: "Terms", value: "Non-transferable. No refunds."}]
    end

    def barcodes
      [{
        format:          "PKBarcodeFormatQR",
        message:         @generator.qr_token,
        messageEncoding: "iso-8859-1",
        altText:         "Ticket ##{@generator.id}"
      }]
    end
  end
end
```

Register it so the dashboard can preview it (optional but useful in dev):

```ruby
Passkit.configure do |config|
  config.available_passes["MyApp::EventPass"] = -> { Ticket.first }
  config.pass_classes << "MyApp::EventPass"
  config.pass_generators << "Ticket"
end
```

Place your images in `private/passkit/event_pass/icon.png` (+ `@2x`, `@3x`) and you're done. Apple's [Pass Design and Creation](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html) page documents the image dimensions and which images each pass style supports.

`serial_number` and `authentication_token` are generated automatically on the `Passkit::Pass` row — you do not set or pass them. Apple's pass-update protocol uses them; your code shouldn't need to touch them.

The next section ("Event tickets") covers the eventTicket-specific fields — `semantics`, `relevant_date`, `locations`, `beacons`, `grouping_identifier` — that you'll want once the basic example is rendering correctly.

### Event tickets

Event tickets need a few things beyond the basic field arrays above to render and behave correctly. The bundled [`Passkit::UserTicket`](test/dummy/app/lib/passkit/user_ticket.rb) is a complete working example.

**Declare the style:**

```ruby
def pass_type
  :eventTicket
end
```

**Required and recommended images** (drop into `private/passkit/<your_downcased_passname>/`):

| File                | Required? | Notes |
|---------------------|-----------|-------|
| `icon.png` (+ `@2x`, `@3x`) | yes — gem raises without it | shown in notifications and Mail attachments |
| `logo.png` (+ `@2x`)        | recommended | top-left corner (legacy layout) |
| `background.png` (+ `@2x`)  | choose one  | full-bleed background (legacy `background + thumbnail` layout) |
| `thumbnail.png` (+ `@2x`)   | choose one  | right-side image (artist headshot, venue photo) |
| `strip.png` (+ `@2x`)       | choose one  | banner above the fields if you don't use background |
| iOS 18+ poster-style images | optional    | full-bleed event poster + branded event logo for the enhanced layout. See note below. |

> **Poster-style image filenames are not pinned in Apple's public docs.** Different references use `artwork.png`, `eventStrip.png`, and `eventLogo.png` interchangeably. The gem's `Generator` copies *every* file in `pass_path` recursively into the signed `.pkpass`, so supply whichever filenames your target iOS version expects — there's no asset-name validation to fight. If you discover the canonical name for your iOS version, contributing it back here helps the next person.

**Field layout convention** (the gem does not enforce these — Apple's renderer just truncates extras):

* `primary_fields` — at most 1 (typically the event name)
* `secondary_fields` — up to 4
* `auxiliary_fields` — up to 4
* `header_fields` — typically 0–1
* `back_fields` — unlimited

**Apple typed event semantics.** These are the keys iOS keys off for lock-screen surfacing, the Smart Stack widget, and Siri prompts. Without them, those integrations don't fire — the field arrays alone are not enough. Full list at [Apple's SemanticTags reference](https://developer.apple.com/documentation/walletpasses/semantictags):

```ruby
def semantics
  {
    eventType: "PKEventTypeLivePerformance",
    eventName: "Showcase 2026",
    venueName: "The Greek Theatre",
    venueLocation: { latitude: 37.8702, longitude: -122.2553 },
    eventStartDate: ticket.starts_at.iso8601,
    eventEndDate:   ticket.ends_at.iso8601,
    performerNames: ticket.performer_names,
    seats: [{
      seatSection: ticket.section,
      seatRow:     ticket.row,
      seatNumber:  ticket.number,
      seatType:    "Reserved"
    }]
  }
end
```

**Surfacing rules:**

* `relevant_date` — set to the show start. iOS surfaces the pass on the lock screen around this time, independent of any geofence.
* `locations` + `max_distance` — venue lat/long with a meters radius. iOS surfaces the pass when the device is inside the radius.
* `beacons` — array of iBeacon `{ proximityUUID, major, minor, relevantText }`. Use for in-venue check-in proximity.
* `grouping_identifier` — string. Multi-ticket purchases sharing the same identifier collapse into one stack in Wallet. Use the order ID.
* `expiration_date` — ISO 8601 timestamp. Apple greys the pass out after this.
* `voided` — boolean. Set to `true` when a ticket is cancelled / refunded; iOS will mark it voided on next update.

Updates flow over the standard PassKit Web Service: when `Ticket#updated_at` advances (or your subclass overrides `last_update`), iOS Wallet's next poll picks up the new `pass.json` via `webServiceURL` + `authentication_token`.

#### Enhanced (iOS 18+) event tickets

iOS 18 introduced a poster-style event ticket layout: full-bleed background, prominent event logo lockup, additional info rows in the detail view, and tappable venue utility URLs (parking, food, bag policy, etc.). It is **opt-in** via `preferred_style_schemes` — passes that don't set it render the legacy card layout. iOS ≤17 ignores the new keys and falls back to the legacy layout, so populating both code paths gives you a single pass that renders correctly on every supported iOS version.

```ruby
# app/lib/my_app/concert_ticket.rb
class MyApp::ConcertTicket < Passkit::BasePass
  def pass_type             = :eventTicket
  def preferred_style_schemes = ["posterEventTicket"]
  def event_logo_text       = "FEST 2026"

  # Detail-view rows (iOS 18+).
  def additional_info_fields
    [
      { key: "doors",    label: "DOORS",    value: ticket.doors_at.iso8601,
        dateStyle: "PKDateStyleNone", timeStyle: "PKDateStyleShort" },
      { key: "duration", label: "DURATION", value: "Approx. 3 hours" }
    ]
  end

  # iOS 18+ relevance windows (each capped at 24h by Apple). Both
  # `relevant_date` and `relevant_dates` may be set; iOS 18+ prefers the plural.
  def relevant_dates
    [{ startDate: ticket.starts_at.iso8601, endDate: ticket.ends_at.iso8601 }]
  end

  # Venue utility URLs — surface as tappable rows in the detail view.
  def bag_policy_url           = "https://venue.example.com/bag-policy"
  def parking_information_url  = "https://venue.example.com/parking"
  def merchandise_url          = "https://venue.example.com/merch"
  def contact_venue_email      = "venue@example.com"
  def contact_venue_phone_number = "+15555550100"
end
```

The enhanced layout keys off the typed semantic tags. Without these, the lock-screen surfacing, Live Activities, and Smart Stack integrations don't fire — populate the same `semantics` hash you'd use for the legacy layout, plus the iOS 18+ additions:

```ruby
def semantics
  {
    eventType: "PKEventTypeLivePerformance",
    eventName: "Showcase 2026",
    genre: "Live Performance",
    venueName: "The Greek Theatre",
    venueLocation: { latitude: 37.8702, longitude: -122.2553 },
    venueEntrance: { latitude: 37.8704, longitude: -122.2555 }, # iOS 18+
    venueDoorsOpenDate: ticket.doors_at.iso8601,                 # iOS 18+
    eventStartDate:    ticket.starts_at.iso8601,
    eventEndDate:      ticket.ends_at.iso8601,
    performerNames:    ticket.performer_names,
    attendeeName:      user.name,                                # iOS 18+
    admissionLevel:    "General Admission",                      # iOS 18+
    admissionLevelAbbreviation: "GA",                            # iOS 18+
    seats: [{ seatSection: ticket.section, seatRow: ticket.row,
              seatNumber: ticket.number,   seatType: "Reserved" }]
  }
end
```

**Caveats:**

* The poster-style layout requires iOS 18 or later. On iOS ≤17 the new keys are silently ignored and Wallet renders the legacy `header/primary/secondary/auxiliary` field arrays — keep them populated.
* NFC may be required for the poster style to actually activate (community-reported, not Apple-documented). If your test pass installs but renders as the legacy card on iOS 18+, populate `nfc` (`{ message:, encryptionPublicKey:, requiresAuthentication: }`) and re-test.
* The `Passkit::Validator` runs every generated `pass.json` through a schema check before signing. If you hit a `Passkit::ValidationError` on a shape Apple actually accepts, set `Passkit.configuration.validate_pass_json = false` as a temporary escape hatch and file an issue.

The bundled [`Passkit::UserTicket`](test/dummy/app/lib/passkit/user_ticket.rb) is a complete enhanced-layout reference — it sets every iOS 18+ key, populates the expanded semantic tags, ships venue utility URLs, and includes English + Spanish localized strings (next section).

#### Localized event tickets

Wallet substitutes field `value`s at render time per the device language using `<lang>.lproj/pass.strings` files inside the signed `.pkpass`. Declare translations on your subclass and the gem writes the files for you:

```ruby
class MyApp::ConcertTicket < Passkit::BasePass
  # Default locale used for `I18n.with_locale` during generation. Optional —
  # leave nil to fall back to the host app's default.
  def language = "en"

  def localized_strings
    {
      en: { "EVENT" => "Event",  "DOORS" => "Doors",   "SEAT" => "Seat" },
      es: { "EVENT" => "Evento", "DOORS" => "Puertas", "SEAT" => "Asiento" },
      fr: { "EVENT" => "Événement", "DOORS" => "Portes", "SEAT" => "Siège" }
    }
  end

  # Reference the localization keys as field `value`s. Wallet substitutes
  # them at render time per the device's preferred language.
  def primary_fields
    [{ key: "event", label: "EVENT", value: "EVENT" }]
  end
end
```

Locales the device doesn't request fall back to whatever literal string is in the field `value` — so if a German user installs the pass above, "EVENT" appears verbatim. Add a `de:` entry to `localized_strings` to localize for them. Per-language images are out of scope for the helper today; drop them into the pass folder via `add_other_files(path)` if you need them.

### Serve your Wallet Pass

Use [`Passkit::UrlGenerator`](lib/passkit/url_generator.rb) to build the download URL. The URL is a single AES-256-GCM-encrypted payload with a 30-day TTL — there is no separate "create" call. The pass is generated and signed lazily on first request.

For a single pass, pass the class plus the AR record that drives it:

```ruby
Passkit::UrlGenerator.new(MyApp::LoyaltyCard, User.find(1)).ios
# => "https://your.host/passkit/api/v1/passes/<encrypted-payload>"
```

For multiple passes (one URL serves N passes from a `has_many`), pass the association name as the third argument:

```ruby
Passkit::UrlGenerator.new(MyApp::EventTicket, User.find(1), :tickets).ios
# => bundle URL — iOS Wallet receives a .pkpasses zip;
#    Android/browsers receive an HTML index of one .pkpass per ticket.
```

`#ios` and `#android` return the same URL — both serve the same `.pkpass`. The android alias exists so calling code reads honestly: `url.android` makes it explicit to readers that the URL goes to a non-iOS user.

### Distributing the URL (mailers, in-app, SMS)

Build the URL once and embed it like any other link. The bundled [`ExampleMailer`](app/mailers/passkit/example_mailer.rb) shows the basic pattern:

```ruby
class TicketMailer < ApplicationMailer
  def confirmation(ticket)
    @url_generator = Passkit::UrlGenerator.new(MyApp::EventTicket, ticket)
    mail(to: ticket.user.email, subject: "Your ticket")
  end
end
```

In the template:

```erb
<a href="<%= @url_generator.ios %>">Add to Apple Wallet</a>
<a href="<%= @url_generator.android %>">Add to your Android wallet</a>
```

For mailer previews, drop a file under `spec/mailers/previews/`:

```ruby
class TicketMailerPreview < ActionMailer::Preview
  def confirmation
    TicketMailer.confirmation(Ticket.first)
  end
end
```

and view it at `http://localhost:3000/rails/mailers/`.

### Pass updates flow (iOS only)

When iOS Wallet installs a `.pkpass`, it registers the device against the gem's PassKit Web Service endpoints. From then on, iOS periodically polls `webServiceURL` and uses the `Last-Modified` response header to decide whether to fetch a fresh `pass.json`.

The header is derived automatically: `Passkit::Pass#last_update` returns `instance.last_update || updated_at`, and `Passkit::BasePass#last_update` returns `@generator&.updated_at`. So whenever your generator AR record is `touch`ed or updated, the next poll picks up the new pass — no extra wiring needed.

If you need different timing (e.g. only count specific column changes as updates), override `last_update` in your subclass:

```ruby
def last_update
  @generator.gate_assignments.maximum(:updated_at) || @generator.updated_at
end
```

Push notifications (APNs) to nudge devices to poll *now* are not implemented in this gem — devices update on their own polling schedule.

## Debug issues 

* On Mac, you can open the *.pkpass files with "Pass Viewer". Open the `Console.app` to log possible error messages and filter by "Pass Viewer" process.
* Check the logs on http://localhost:3000/passkit/dashboard/logs
* In case of error "The passTypeIdentifier or teamIdentifier provided may not match your certificate, 
or the certificate trust chain could not be verified." the certificate (p12) might be expired.


## Apple documentation

* [Apple Wallet Passes](https://developer.apple.com/documentation/walletpasses)
* [Send Push Notifications](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/sending_notification_requests_to_apns)

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/coorasse/passkit. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/coorasse/passkit/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Passkit project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/coorasse/passkit/blob/master/CODE_OF_CONDUCT.md).

## Credits

* <a href="https://www.flaticon.com/free-icons/credit-card" title="credit card icons">Credit card icons created by Iconfromus - Flaticon</a>

* https://www.sitepoint.com/whats-in-your-wallet-handling-ios-passbook-with-ruby/
