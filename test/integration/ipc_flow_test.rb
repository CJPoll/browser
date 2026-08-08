require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../support/test_clock'
require_relative '../../lib/adapters/ipc_file'
require_relative '../../lib/managers/ipc_manager'

# The single-instance hand-off end to end: a second invocation publishes its
# URL and exits, and the running browser picks it up. Real file, no mocks.
class IpcFlowTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @data_dir = Dir.mktmpdir('ipc-flow-test')
    @clock = TestClock.new(NOW)
    # The browser that is already running
    @running = build_manager
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && Dir.exist?(@data_dir)
  end

  def build_manager
    Managers::IpcManager.new(
      ipc_file: Adapters::IpcFile.new(data_dir: @data_dir),
      clock: @clock
    )
  end

  def test_a_second_invocation_hands_its_url_to_the_running_browser
    build_manager.publish(url: 'https://example.com')

    request = @running.take_pending_request
    assert_equal 'https://example.com', request.url
    refute request.new_window?
  end

  def test_a_new_window_request_survives_the_hand_off
    build_manager.publish(url: 'https://example.com', new_window: true)

    assert @running.take_pending_request.new_window?
  end

  def test_a_bare_new_window_request_carries_no_url
    build_manager.publish(new_window: true)

    request = @running.take_pending_request
    refute request.url?
    assert request.new_window?
  end

  # The running browser polls several times a second; it must not open the
  # same URL on every tick.
  def test_a_request_is_acted_on_only_once
    build_manager.publish(url: 'https://example.com')
    @running.take_pending_request

    assert_nil @running.take_pending_request
  end

  def test_each_invocation_is_acted_on_in_turn
    build_manager.publish(url: 'https://first.example')
    assert_equal 'https://first.example', @running.take_pending_request.url

    @clock.advance(5)
    build_manager.publish(url: 'https://second.example')
    assert_equal 'https://second.example', @running.take_pending_request.url
  end

  # The URL is written before the window exists, so the first poll has to see
  # a request that predates the browser it is talking to.
  def test_a_url_published_before_the_browser_started_is_still_opened
    build_manager.publish(url: 'https://example.com')
    @clock.advance(2)

    assert_equal 'https://example.com', build_manager.take_pending_request.url
  end

  def test_nothing_is_pending_when_no_one_asked_for_anything
    assert_nil @running.take_pending_request
  end
end
