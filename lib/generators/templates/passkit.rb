Passkit.configure do |config|
  # config.available_passes['Passkit::YourPass'] = -> { User.create }

  # APNs pass update pushes, sent by Passkit::PushUpdateJob after
  # Passkit::Pass#mark_updated!. Keep off in test, CI and development.
  # config.push_enabled = ENV["PASSKIT_PUSH_ENABLED"] == "1"
end
