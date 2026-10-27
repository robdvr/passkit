# frozen_string_literal: true

require "rails_helper"
class TestLogsController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def test_show
    post log_url, params: {"logs" => ["message 1", "message 2", "message 3"]}
    assert_equal 3, Passkit::Log.count
    assert_response :success
    assert_equal "{}", response.body
  end

  def test_create_with_empty_logs_array_creates_no_logs_returns_200
    post log_url, params: {logs: []}.to_json, headers: {"Content-Type" => "application/json"}
    assert_equal 0, Passkit::Log.count
    assert_response :success
  end

  def test_create_without_logs_param_is_a_noop_returning_200
    # Fixed in app/controllers/passkit/api/v1/logs_controller.rb — params[:logs]
    # is wrapped in Array(...) so a missing param results in zero log records
    # and a clean 200, matching how Apple's device sometimes posts an empty body.
    post log_url
    assert_response :success
    assert_equal 0, Passkit::Log.count
  end

  def test_create_persists_exact_log_strings
    messages = ["log alpha", "log beta", "log gamma"]
    post log_url, params: {"logs" => messages}
    assert_response :success
    persisted = Passkit::Log.order(:id).pluck(:content)
    assert_equal messages, persisted
  end

  def test_create_response_body_is_empty_json_object
    post log_url, params: {"logs" => ["only one"]}
    assert_equal "{}", response.body
  end

  # The endpoint is unauthenticated (Apple's spec), so one request can only
  # write a bounded amount: the first MAX_ENTRIES messages, each cut to
  # MAX_LENGTH characters.
  def test_create_bounds_what_one_request_can_store
    max_entries = Passkit::Api::V1::LogsController::MAX_ENTRIES
    max_length = Passkit::Api::V1::LogsController::MAX_LENGTH
    logs = Array.new(max_entries + 5) { |i| "m#{i}" }
    logs[0] = "x" * (max_length + 100)
    post log_url, params: {logs: logs}.to_json, headers: {"Content-Type" => "application/json"}
    assert_response :success
    assert_equal max_entries, Passkit::Log.count
    assert_equal max_length, Passkit::Log.order(:id).first.content.length
  end

  def test_create_ignores_non_string_entries
    post log_url, params: {logs: ["ok", {"nested" => "x"}, 5]}.to_json, headers: {"Content-Type" => "application/json"}
    assert_response :success
    assert_equal ["ok", "5"], Passkit::Log.order(:id).pluck(:content)
  end
end
