# frozen_string_literal: true

require "rails_helper"

class TestDashboardLogsController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def basic_auth_headers(user = ENV["PASSKIT_DASHBOARD_USERNAME"], pass = ENV["PASSKIT_DASHBOARD_PASSWORD"])
    {"Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass)}
  end

  def test_index_without_auth_returns_401
    get dashboard_logs_path
    assert_response :unauthorized
  end

  def test_index_with_auth_returns_200
    get dashboard_logs_path, headers: basic_auth_headers
    assert_response :ok
  end

  def test_index_paginates_to_first_100
    Passkit::Log.delete_all
    101.times do |i|
      Passkit::Log.create!(content: "log-line-marker-#{i}-#{SecureRandom.hex(4)}")
    end

    get dashboard_logs_path, headers: basic_auth_headers
    assert_response :ok

    contents = Passkit::Log.order(created_at: :desc).pluck(:content)
    assert_equal 101, contents.size

    rendered = contents.select { |c| response.body.include?(c) }
    assert_equal 100, rendered.size
    # The oldest log (last in desc order) must be excluded by the .first(100) cap.
    refute_includes rendered, contents.last
  end

  def test_index_orders_by_created_at_desc
    Passkit::Log.delete_all
    older = Passkit::Log.create!(content: "older-log-#{SecureRandom.hex(4)}", created_at: 2.minutes.ago)
    newer = Passkit::Log.create!(content: "newer-log-#{SecureRandom.hex(4)}", created_at: 1.minute.ago)

    get dashboard_logs_path, headers: basic_auth_headers
    assert_response :ok

    newer_idx = response.body.index(newer.content)
    older_idx = response.body.index(older.content)
    refute_nil newer_idx, "expected newer log content in response body"
    refute_nil older_idx, "expected older log content in response body"
    assert newer_idx < older_idx, "expected newer log to appear before older log in body"
  end
end
