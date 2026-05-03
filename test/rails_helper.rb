# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start "rails" do
    add_filter "/test/"
    enable_coverage :branch if ENV["COVERAGE_BRANCH"]
  end
end

# Boot Bundler against the gem's Gemfile (the dummy app's boot.rb does this too,
# but we need it before requiring 'passkit' below).
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"

# Generate ephemeral test certs and set required PASSKIT_* env vars BEFORE the
# dummy app boots — Passkit::Configuration#initialize raises eagerly on missing
# vars when `Passkit.configure` runs in the dummy's initializer.
require_relative "support/cert_helper"
Passkit::CertHelper.install!

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require "capybara/rails"
require "rails-controller-testing"

Capybara.server = :webrick

# Prepare DB schema (the dummy app uses SQLite; ensure tables match current schema).
ActiveRecord::Tasks::DatabaseTasks.prepare_all if ActiveRecord::Tasks::DatabaseTasks.respond_to?(:prepare_all)

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_paths.first + "/files"
  ActiveSupport::TestCase.fixtures :all
elsif ActiveSupport::TestCase.respond_to?(:fixture_path=)
  # Rails < 7.1 compat (kept just in case)
  ActionDispatch::IntegrationTest.fixture_path = ActiveSupport::TestCase.fixture_path
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_path + "/files"
  ActiveSupport::TestCase.fixtures :all
end
