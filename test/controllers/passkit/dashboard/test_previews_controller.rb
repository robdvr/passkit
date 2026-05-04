# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"

class TestDashboardPreviewsController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  setup do
    @routes = Passkit::Engine.routes
  end

  def basic_auth_headers(user = ENV["PASSKIT_DASHBOARD_USERNAME"], pass = ENV["PASSKIT_DASHBOARD_PASSWORD"])
    {"Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass)}
  end

  def test_index_without_auth_returns_401
    get dashboard_previews_path
    assert_response :unauthorized
  end

  def test_index_with_wrong_password_returns_401
    get dashboard_previews_path,
      headers: basic_auth_headers(ENV["PASSKIT_DASHBOARD_USERNAME"], "wrong-password")
    assert_response :unauthorized
  end

  def test_index_with_correct_basic_auth_returns_200
    get dashboard_previews_path, headers: basic_auth_headers
    assert_response :ok
  end

  def test_index_lists_available_pass_classes
    get dashboard_previews_path, headers: basic_auth_headers
    assert_response :ok
    assert_includes response.body, "Passkit::ExampleStoreCard"
  end

  def test_show_with_valid_class_name_returns_pkpass
    get dashboard_preview_path(class_name: "Passkit::ExampleStoreCard"),
      headers: basic_auth_headers
    assert_response :ok
    assert_includes response.headers["Content-Type"].to_s, "application/vnd.apple.pkpass"
  end

  def test_show_with_unknown_class_name_returns_404
    # Fixed in app/controllers/passkit/dashboard/previews_controller.rb#show —
    # an unknown class_name now raises ActionController::RoutingError, which the
    # Rails stack renders as 404.
    get dashboard_preview_path(class_name: "Passkit::DoesNotExist"),
      headers: basic_auth_headers
    assert_response :not_found
  end

  def test_custom_authenticate_dashboard_with_block_is_used
    custom_auth = proc { head :forbidden }
    Passkit.configuration.stubs(:authenticate_dashboard_with).returns(custom_auth)

    get dashboard_previews_path
    assert_response :forbidden
  end
end
