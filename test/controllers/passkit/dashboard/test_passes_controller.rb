# frozen_string_literal: true

require "rails_helper"

class TestDashboardPassesController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def basic_auth_headers(user = ENV["PASSKIT_DASHBOARD_USERNAME"], pass = ENV["PASSKIT_DASHBOARD_PASSWORD"])
    {"Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass)}
  end

  def test_index_without_auth_returns_401
    get dashboard_passes_path
    assert_response :unauthorized
  end

  def test_index_with_auth_returns_200
    get dashboard_passes_path, headers: basic_auth_headers
    assert_response :ok
  end

  def test_index_paginates_to_first_100
    Passkit::Pass.delete_all
    assert_equal 0, Passkit::Pass.count
    user = User.find(1)
    101.times do
      Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard", generator: user)
    end
    assert_equal 101, Passkit::Pass.count

    get dashboard_passes_path, headers: basic_auth_headers
    assert_response :ok

    # The view renders one <tr> per pass inside <tbody>; the controller caps at 100.
    tbody = response.body[/<tbody>(.+?)<\/tbody>/m, 1]
    refute_nil tbody, "expected a <tbody> in the rendered response"
    rendered_rows = tbody.scan("<tr>").size
    assert_equal 100, rendered_rows
  end

  def test_index_orders_by_created_at_desc
    Passkit::Pass.delete_all
    user1 = User.find(1)
    user2 = User.find(2)
    older = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard", generator: user1, created_at: 2.minutes.ago)
    newer = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard", generator: user2, created_at: 1.minute.ago)
    assert_equal 2, Passkit::Pass.count
    refute_equal older.id, newer.id

    get dashboard_passes_path, headers: basic_auth_headers
    assert_response :ok

    # The rendered cells include "User - 1" for `older` and "User - 2" for `newer`.
    newer_idx = response.body.index("User - #{user2.id}")
    older_idx = response.body.index("User - #{user1.id}")
    refute_nil newer_idx, "expected newer pass generator label in response body"
    refute_nil older_idx, "expected older pass generator label in response body"
    assert newer_idx < older_idx, "expected newer pass to appear before older pass in body"
  end
end
