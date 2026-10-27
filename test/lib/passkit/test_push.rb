# frozen_string_literal: true

require "rails_helper"
require "mocha/minitest"
require "apnotic"

class TestPush < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Stands in for Apnotic::Connection: records each notification and answers
  # with the status scripted for its device token (200 when none is).
  class FakeConnection
    attr_reader :pushed, :closed

    def initialize(statuses = {})
      @statuses = statuses
      @pushed = []
      @closed = false
    end

    def push(notification, _options = {})
      @pushed << notification
      status, reason = @statuses.key?(notification.token) ? @statuses[notification.token] : (@statuses.default || "200")
      return nil if status == :timeout
      Apnotic::Response.new(headers: {":status" => status}, body: reason ? {reason: reason}.to_json : "")
    end

    def close
      @closed = true
    end
  end

  def pass_with_devices(*tokens)
    pass = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    tokens.each_with_index do |token, i|
      device = Passkit::Device.create!(identifier: "device-#{SecureRandom.hex(4)}-#{i}", push_token: token)
      pass.registrations.create!(device: device)
    end
    pass
  end

  def push(pass_ids, statuses = {})
    connection = FakeConnection.new(statuses)
    result = Passkit::Push.new(connection: connection).call(pass_ids)
    [connection, result]
  end

  # Apple: the update push carries an empty JSON dictionary, is addressed to
  # the token the device registered, and its topic is the pass type id.
  def test_sends_an_empty_dictionary_to_each_registered_token
    pass = pass_with_devices("token-a", "token-b")
    connection, result = push([pass.id])

    assert_equal %w[token-a token-b], connection.pushed.map(&:token).sort
    connection.pushed.each do |notification|
      assert_equal "{}", notification.body
      assert_equal ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], notification.topic
    end
    assert_equal 2, result.sent
    assert connection.closed
  end

  # Two passes on one phone (a group order) is one push: Wallet then asks
  # which serials changed and fetches each.
  def test_pushes_a_device_once_however_many_of_its_passes_changed
    pass = pass_with_devices("shared")
    other = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard")
    other.registrations.create!(device: Passkit::Device.find_by!(push_token: "shared"))

    connection, _result = push([pass.id, other.id])
    assert_equal ["shared"], connection.pushed.map(&:token)
  end

  def test_skips_devices_without_a_push_token
    pass = pass_with_devices(nil, "")
    connection, result = push([pass.id])
    assert_empty connection.pushed
    assert_equal 0, result.sent
  end

  # Apple: delete a device when APNs says its token is no longer valid.
  [
    ["410", "Unregistered"],
    ["400", "BadDeviceToken"],
    ["400", "DeviceTokenNotForTopic"]
  ].each do |status, reason|
    define_method(:"test_removes_the_device_when_apns_answers_#{status}_#{reason}") do
      pass = pass_with_devices("dead", "alive")
      _connection, result = push([pass.id], {"dead" => [status, reason]})

      assert_equal 1, result.removed
      assert_nil Passkit::Device.find_by(push_token: "dead")
      assert Passkit::Device.exists?(push_token: "alive")
      assert_equal 1, pass.registrations.count
    end
  end

  # A timeout, throttling or an APNs outage is worth retrying; the error is
  # raised after every other device was tried and names only the devices
  # still owed a push, so a retry reaches those alone.
  [:timeout, "429", "500", "503"].each do |status|
    define_method(:"test_raises_after_the_batch_on_a_transient_#{status}") do
      pass = pass_with_devices("flaky", "fine")
      connection = FakeConnection.new({"flaky" => [status, "TooManyRequests"]})
      error = assert_raises(Passkit::PushError) { Passkit::Push.new(connection: connection).call([pass.id]) }

      assert_includes error.message, "1 of 2"
      assert_equal [Passkit::Device.find_by!(push_token: "flaky").id], error.failed_device_ids
      assert_equal %w[fine flaky], connection.pushed.map(&:token).sort, "every device is still tried"
      assert Passkit::Device.exists?(push_token: "flaky"), "a transient failure never removes a device"
    end
  end

  def test_a_retry_reaches_only_the_devices_still_owed_a_push
    pass = pass_with_devices("done", "owed")
    connection = FakeConnection.new
    Passkit::Push.new(connection: connection).call([pass.id], device_ids: [Passkit::Device.find_by!(push_token: "owed").id])
    assert_equal ["owed"], connection.pushed.map(&:token)
  end

  # APNs that stops answering would hold a worker for every device's
  # timeout; after a few in a row the rest of the batch is owed instead.
  def test_stops_trying_once_apns_stops_answering
    tokens = Array.new(6) { |i| "t#{i}" }
    pass = pass_with_devices(*tokens)
    connection = FakeConnection.new(Hash.new([:timeout].freeze))
    error = assert_raises(Passkit::PushError) { Passkit::Push.new(connection: connection).call([pass.id]) }

    assert_equal Passkit::Push::MAX_CONSECUTIVE_TIMEOUTS, connection.pushed.size
    assert_equal 6, error.failed_device_ids.size
  end

  # A bad certificate or topic fails every push the same way: stop at once
  # with APNs' reason instead of spending the batch, and never retry.
  def test_stops_at_the_first_certificate_or_topic_error
    pass = pass_with_devices("a", "b", "c")
    connection = FakeConnection.new(Hash.new(["403", "BadCertificate"].freeze))
    error = assert_raises(Passkit::PushFatalError) { Passkit::Push.new(connection: connection).call([pass.id]) }

    assert_includes error.message, "BadCertificate"
    refute_kind_of Passkit::PushError, error
    assert_equal 1, connection.pushed.size
    assert_equal 3, Passkit::Device.count
    assert connection.closed
  end

  def test_signs_in_with_the_pass_type_certificate_on_production_apns
    Apnotic::Connection.expects(:new).with(
      cert_path: Rails.root.join(ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"]).to_s,
      cert_pass: ENV["PASSKIT_CERTIFICATE_KEY"],
      url: "https://api.push.apple.com:443"
    ).returns(FakeConnection.new)
    Passkit::Push.new.call([pass_with_devices("t").id])
  end

  def test_opens_no_connection_when_no_device_has_a_token
    Apnotic::Connection.expects(:new).never
    result = Passkit::Push.new.call([pass_with_devices(nil).id])
    assert_equal 0, result.sent
  end

  # ---- Pass#mark_updated! and the job ----

  def with_push_enabled(enabled)
    previous = Passkit.configuration.push_enabled
    Passkit.configuration.push_enabled = enabled
    yield
  ensure
    Passkit.configuration.push_enabled = previous
  end

  def test_push_is_off_by_default
    assert_equal false, Passkit::Configuration.new.push_enabled
  end

  def test_mark_updated_touches_the_pass_and_enqueues_a_push
    pass = pass_with_devices("t")
    pass.update_columns(updated_at: 1.day.ago)

    with_push_enabled(true) do
      assert_enqueued_with(job: Passkit::PushUpdateJob, args: [[pass.id]]) { pass.mark_updated! }
    end
    assert_in_delta Time.current, pass.reload.updated_at, 5
  end

  def test_mark_updated_with_push_off_only_touches_the_pass
    pass = pass_with_devices("t")
    pass.update_columns(updated_at: 1.day.ago)

    with_push_enabled(false) do
      assert_no_enqueued_jobs { pass.mark_updated! }
    end
    assert_in_delta Time.current, pass.reload.updated_at, 5
  end

  # The bulk form (an event's every ticket) is one UPDATE and one job per
  # batch of ids, not one per pass.
  def test_mark_updated_for_many_passes_batches_the_jobs
    passes = Array.new(3) { pass_with_devices("t-#{SecureRandom.hex(3)}") }
    Passkit::Pass.where(id: passes.map(&:id)).update_all(updated_at: 1.day.ago)

    with_push_enabled(true) do
      assert_enqueued_jobs(2, only: Passkit::PushUpdateJob) do
        assert_equal 3, Passkit::Pass.mark_updated!(Passkit::Pass.where(id: passes.map(&:id)), batch_size: 2)
      end
    end
    passes.each { |p| assert_in_delta Time.current, p.reload.updated_at, 5 }
  end

  def test_job_sends_the_push
    pass = pass_with_devices("t")
    Passkit::Push.any_instance.expects(:call).with([pass.id], device_ids: nil).returns(Passkit::Push::Result.new(sent: 1, removed: 0))
    with_push_enabled(true) { Passkit::PushUpdateJob.perform_now([pass.id]) }
  end

  def test_job_retries_only_the_devices_still_owed_a_push
    Passkit::Push.any_instance.stubs(:call).raises(Passkit::PushError.new("1 of 2 failed", failed_device_ids: [7]))
    with_push_enabled(true) do
      assert_enqueued_with(job: Passkit::PushUpdateJob, args: [[1], [7], 2]) { Passkit::PushUpdateJob.perform_now([1]) }
    end
  end

  def test_job_reports_and_stops_after_the_last_attempt
    Passkit::Push.any_instance.stubs(:call).raises(Passkit::PushError.new("still failing", failed_device_ids: [7]))
    Rails.error.expects(:report).with(instance_of(Passkit::PushError), handled: true)
    with_push_enabled(true) do
      assert_no_enqueued_jobs(only: Passkit::PushUpdateJob) do
        Passkit::PushUpdateJob.perform_now([1], [7], Passkit::PushUpdateJob::MAX_ATTEMPTS)
      end
    end
  end

  def test_job_reports_a_fatal_error_and_never_retries_it
    Passkit::Push.any_instance.stubs(:call).raises(Passkit::PushFatalError, "BadCertificate")
    Rails.error.expects(:report).with(instance_of(Passkit::PushFatalError), handled: true)
    with_push_enabled(true) do
      assert_no_enqueued_jobs(only: Passkit::PushUpdateJob) { Passkit::PushUpdateJob.perform_now([1]) }
    end
  end

  def test_job_does_nothing_when_push_is_switched_off_after_enqueue
    with_push_enabled(false) do
      Passkit::Push.any_instance.expects(:call).never
      Passkit::PushUpdateJob.perform_now([1])
    end
  end
end
