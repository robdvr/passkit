# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    enable_coverage :branch if ENV["COVERAGE_BRANCH"]
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require_relative "support/cert_helper"
Passkit::CertHelper.install!
require "passkit"

require "minitest/autorun"
