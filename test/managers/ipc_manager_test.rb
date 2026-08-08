require 'minitest/autorun'
require_relative '../support/test_clock'
require_relative '../../lib/managers/ipc_manager'

class ManagersIpcManagerTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  class MockIpcFile
    attr_reader :written, :deletes

    def initialize(pending: nil)
      @pending = pending
      @written = []
      @deletes = 0
    end

    def write(message)
      @written << message
      @pending = message
    end

    def read
      @pending
    end

    def delete
      @deletes += 1
      @pending = nil
    end
  end

  def build_message(url: 'https://example.com', timestamp: NOW.to_f, new_window: false)
    Domain::IpcMessage.new(url: url, timestamp: timestamp, new_window: new_window)
  end

  def setup
    @clock = TestClock.new(NOW)
    @ipc_file = MockIpcFile.new
    @manager = Managers::IpcManager.new(ipc_file: @ipc_file, clock: @clock)
  end

  # === Publishing (the second instance) ===

  def test_publishes_a_url_for_the_running_browser
    @manager.publish(url: 'https://example.com')

    assert_equal 'https://example.com', @ipc_file.written.first.url
  end

  def test_stamps_the_request_with_the_current_time
    @clock.advance(30)
    @manager.publish(url: 'https://example.com')

    assert_equal NOW.to_f + 30, @ipc_file.written.first.timestamp
  end

  def test_publishes_a_request_for_a_new_window
    @manager.publish(url: 'https://example.com', new_window: true)

    assert @ipc_file.written.first.new_window?
  end

  def test_publishes_a_bare_new_window_request_with_no_url
    @manager.publish(new_window: true)

    refute @ipc_file.written.first.url?
    assert @ipc_file.written.first.new_window?
  end

  def test_returns_the_published_request
    message = @manager.publish(url: 'https://example.com')

    assert_equal 'https://example.com', message.url
  end

  # === Taking requests (the running browser) ===

  def test_takes_a_pending_request
    @ipc_file.write(build_message(url: 'https://example.com'))

    assert_equal 'https://example.com', @manager.take_pending_request.url
  end

  def test_takes_nothing_when_no_request_is_pending
    assert_nil @manager.take_pending_request
  end

  def test_clears_the_request_it_took
    @ipc_file.write(build_message)
    @manager.take_pending_request

    assert_equal 1, @ipc_file.deletes
  end

  # The file is polled several times a second; acting on it twice would open
  # the same URL twice.
  def test_does_not_take_the_same_request_twice
    @ipc_file.write(build_message)
    @manager.take_pending_request

    assert_nil @manager.take_pending_request
  end

  def test_ignores_a_request_older_than_the_last_one_taken
    @ipc_file.write(build_message(timestamp: NOW.to_f))
    @manager.take_pending_request
    @ipc_file.write(build_message(timestamp: NOW.to_f - 60))

    assert_nil @manager.take_pending_request
  end

  def test_takes_a_request_written_after_the_last_one
    @ipc_file.write(build_message(timestamp: NOW.to_f))
    @manager.take_pending_request
    @ipc_file.write(build_message(url: 'https://later.example', timestamp: NOW.to_f + 1))

    assert_equal 'https://later.example', @manager.take_pending_request.url
  end

  # A URL written just before the browser finished starting still counts.
  def test_takes_a_request_that_predates_the_manager
    @ipc_file.write(build_message(timestamp: NOW.to_f - 3600))

    refute_nil @manager.take_pending_request
  end

  def test_leaves_a_stale_request_in_place
    @ipc_file.write(build_message(timestamp: NOW.to_f))
    @manager.take_pending_request
    @ipc_file.write(build_message(timestamp: NOW.to_f - 60))
    @manager.take_pending_request

    assert_equal 1, @ipc_file.deletes
  end

  # === Round trip ===

  def test_a_published_request_is_taken_by_the_running_browser
    publisher = Managers::IpcManager.new(ipc_file: @ipc_file, clock: @clock)
    publisher.publish(url: 'https://example.com', new_window: true)

    taken = @manager.take_pending_request
    assert_equal 'https://example.com', taken.url
    assert taken.new_window?
  end
end
