# frozen_string_literal: true

require "test_helper"

class TestConfiguration < Minitest::Test
  REQUIRED_ENV_VARS = %w[
    PASSKIT_WEB_SERVICE_HOST
    PASSKIT_CERTIFICATE_KEY
    PASSKIT_PRIVATE_P12_CERTIFICATE
    PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE
    PASSKIT_APPLE_TEAM_IDENTIFIER
    PASSKIT_PASS_TYPE_IDENTIFIER
  ].freeze

  def setup
    # Capture the dummy app's already-initialized configuration so we can
    # exercise Configuration.new in isolation without leaving Passkit.configuration
    # nil for subsequent test classes (the dashboard controllers depend on it).
    @original_configuration = Passkit.configuration
    Passkit.configuration = nil
  end

  def teardown
    Passkit.configuration = @original_configuration
  end

  # Captures original ENV values for the listed keys, applies overrides,
  # yields, and then restores the original values (including re-deleting
  # any keys that were originally unset).
  def with_env(overrides)
    saved = {}
    overrides.each_key { |k| saved[k] = ENV[k] }
    begin
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  def test_raises_for_each_missing_required_env_var
    REQUIRED_ENV_VARS.each do |var|
      with_env(var => nil) do
        error = assert_raises(RuntimeError) { Passkit::Configuration.new }
        assert_includes error.message, "Please set #{var}",
          "Expected error message for missing #{var} to include 'Please set #{var}', got: #{error.message.inspect}"
      end
    end
  end

  def test_raises_when_web_service_host_is_not_https
    ["http://example.com", "ftp://x", "no-scheme.com"].each do |bad_host|
      with_env("PASSKIT_WEB_SERVICE_HOST" => bad_host) do
        error = assert_raises(RuntimeError) { Passkit::Configuration.new }
        assert_includes error.message, "must start with https://",
          "Expected error for host #{bad_host.inspect} to include 'must start with https://', got: #{error.message.inspect}"
      end
    end
  end

  def test_accepts_https_host_with_port_and_path
    host = "https://example.com:8443/passkit"
    with_env("PASSKIT_WEB_SERVICE_HOST" => host) do
      config = Passkit::Configuration.new
      assert_equal host, config.web_service_host
    end
  end

  def test_available_passes_default
    config = Passkit::Configuration.new
    assert config.available_passes.key?("Passkit::ExampleStoreCard"),
      "Expected available_passes to include key 'Passkit::ExampleStoreCard'"
    assert_respond_to config.available_passes["Passkit::ExampleStoreCard"], :call
  end

  def test_authenticate_dashboard_with_returns_default_when_no_block_given
    config = Passkit::Configuration.new
    result = config.authenticate_dashboard_with
    assert_kind_of Proc, result
    assert_same Passkit::Configuration::DEFAULT_AUTHENTICATION, result
  end

  def test_authenticate_dashboard_with_returns_custom_block
    config = Passkit::Configuration.new
    custom = proc { :custom_auth }
    returned = config.authenticate_dashboard_with(&custom)
    assert_same custom, returned
    # Subsequent calls without a block return the stored custom block.
    assert_same custom, config.authenticate_dashboard_with
  end

  def test_passkit_configure_yields_configuration_singleton
    yielded = nil
    Passkit.configure do |c|
      yielded = c
      assert_kind_of Passkit::Configuration, c
    end
    assert_same Passkit.configuration, yielded
  end
end
