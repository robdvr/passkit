# frozen_string_literal: true

require "rails_helper"

class TestPasskitDevice < ActiveSupport::TestCase
  def test_identifier_uniqueness
    Passkit::Device.create!(identifier: "abc", push_token: "tok-1")
    duplicate = Passkit::Device.new(identifier: "abc", push_token: "tok-2")
    refute duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :identifier
  end

  def test_push_token_persists
    d = Passkit::Device.create!(identifier: "dev-1", push_token: "push-token-xyz")
    assert_equal "push-token-xyz", Passkit::Device.find(d.id).push_token
  end

  def test_passes_through_registrations
    pass = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    device = Passkit::Device.create!(identifier: "dev-2", push_token: "tok")
    Passkit::Registration.create!(pass: pass, device: device)
    assert_equal [pass], device.passes.to_a
  end

  def test_registrations_foreign_key_is_passkit_device_id
    assert_equal "passkit_device_id",
      Passkit::Device.reflect_on_association(:registrations).foreign_key.to_s
  end
end
