# frozen_string_literal: true

require "rails_helper"

class TestPasskitLog < ActiveSupport::TestCase
  def test_persists_content
    Passkit::Log.create!(content: "msg")
    assert_equal "msg", Passkit::Log.last.content
  end

  # Pin current behavior: Passkit::Log declares no validations.
  def test_no_required_fields_pinned
    log = Passkit::Log.new
    assert log.valid?
  end

  def test_timestamps_set
    log = Passkit::Log.create!(content: "hello")
    refute_nil log.created_at
    refute_nil log.updated_at
  end
end
