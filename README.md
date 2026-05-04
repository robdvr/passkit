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

* Full tests coverage: we are working on it!
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

## Usage

If you followed the installation steps and you have the ENV variables set, we can start looking at what is provided for you.

### Dashboard

Head to `http://localhost:3000/passkit/dashboard/previews` and you will see a first `ExampleStoreCard` available for download.
You can click on the button and you will obtain a `.pkpass` file that you can simply open or install on your phone.
The dashboard has also a view for logs, and a view for emitted passes.

By default the dashboard is protected with basic auth. Set the credentials using these ENV variables:
* `PASSKIT_DASHBOARD_USERNAME`
* `PASSKIT_DASHBOARD_PASSWORD`

You can also change the authentication method used (see example below for Devise):

```ruby
# config/passkit.rb

Passkit.configure do |config|
  config.authenticate_dashboard_with do
    warden.authenticate! scope: :user
    ## redirect_to main_app.root_path unless warden.user.admin? # if you want to check a specific role
  end
end
```

### Mailer Helpers

If you use mailer previews, you can create the following file in `spec/mailers/previews/passkit/example_mailer_preview.rb`:

```ruby
module Passkit
  class ExampleMailerPreview < ActionMailer::Preview
    def example_email
      Passkit::ExampleMailer.example_email
    end
  end
end
```

and head to `http://localhost:3000/rails/mailers/` to see an example of email with links to download the Wallet Pass.
Please check the source code of [ExampleMailer](app/mailers/passkit/example_mailer.rb) to see how to distribute your own Wallet Passes.

### Example Passes

Please check the source code of the [ExampleStoreCard](lib/passkit/example_store_card.rb) to see how to create your own Wallet Passes.

Again, looking at these examples, is the easiest way to get started.

### Create your own Wallet Pass

You can create your own Wallet Passes by creating a new class that inherits from `Passkit::BasePass` and 
defining the methods that you want to override.

You can define colors, fields and texts. You can also define the logo and the background image.

You should place the images in a 'private/passkit/<your_downcased_passname>' folder.
There is a [dummy app in the gem](test/dummy) that you can use to check how to create your own Wallet Passes.

Full documentation for image specifications is on Apple's
[Pass Design and Creation](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Creating.html)
page. Naming the file according to convetion and putting it in 'private/passkit/<your_downcased_passname>' is all that's needed for it
to be included in the pass.

### Event tickets

Event tickets need a few things beyond the storeCard defaults to render and behave correctly. The bundled [`Passkit::UserTicket`](test/dummy/app/lib/passkit/user_ticket.rb) is a working example.

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
| `logo.png` (+ `@2x`)        | recommended | top-left corner |
| `background.png` (+ `@2x`)  | choose one  | full-bleed background; iOS uses the "background+thumbnail" layout when this is present |
| `thumbnail.png` (+ `@2x`)   | choose one  | right-side image (artist headshot, venue photo) |
| `strip.png` (+ `@2x`)       | choose one  | banner above the fields if you don't use background |

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

### Serve your Wallet Pass

Use the [Passkit::UrlGenerator](lib/passkit/url_generator.rb) to generate the URL to serve your Wallet Pass.
For one pass, you can initialize it with:

```ruby
Passkit::UrlGenerator.new(Passkit::MyPass, User.find(1))
```

For one passes, you can initialize it with:

```ruby
Passkit::UrlGenerator.new(Passkit::UserTicket, User.find(1), :tickets)
```
(this presumes you have `User.find(1).tickets` would return the ticket records)

and then call `.ios` (or its alias `.android`) to get the URL — both return the same `.pkpass` download URL, since the same file is served to either platform. Check the example mailer included in the gem to see how to use it.

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
