# frozen_string_literal: true

require "rails_helper"

class TestPasskitRegistration < ActiveSupport::TestCase
  def test_belongs_to_device_via_passkit_device_id
    reflection = Passkit::Registration.reflect_on_association(:device)
    assert_equal :belongs_to, reflection.macro
    assert_equal "passkit_device_id", reflection.foreign_key.to_s
  end

  def test_belongs_to_pass_via_passkit_pass_id
    reflection = Passkit::Registration.reflect_on_association(:pass)
    assert_equal :belongs_to, reflection.macro
    assert_equal "passkit_pass_id", reflection.foreign_key.to_s
  end

  def test_create_with_pass_and_device_works
    pass = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    device = Passkit::Device.create!(identifier: "reg-dev-1", push_token: "tok")
    registration = Passkit::Registration.new(pass: pass, device: device)
    assert registration.valid?
    assert registration.save
    assert_equal pass, registration.pass
    assert_equal device, registration.device
  end

  # Rails 5+ makes belongs_to required by default (unless `optional: true`).
  def test_creating_without_pass_or_device_invalid_in_rails_8_belongs_to_required_by_default
    registration = Passkit::Registration.new
    refute registration.valid?
    assert_includes registration.errors.attribute_names, :device
    assert_includes registration.errors.attribute_names, :pass
  end
end
