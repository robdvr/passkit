module Passkit
  # Sends the pass update push for a batch of passes (Passkit::Push). Pushes
  # are content-free, so a retry that reaches a device twice costs nothing.
  class PushUpdateJob < ActiveJob::Base
    queue_as :default

    retry_on Passkit::PushError, wait: :polynomially_longer, attempts: 5

    def perform(pass_ids)
      # The switch can be turned off after the job was queued.
      return unless Passkit.configuration&.push_enabled

      Passkit::Push.new.call(pass_ids)
    end
  end
end
