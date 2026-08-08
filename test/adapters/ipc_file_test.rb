require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/adapters/ipc_file'

class AdaptersIpcFileTest < Minitest::Test
  TIMESTAMP = 1_700_000_000.5

  def setup
    @data_dir = Dir.mktmpdir('ipc-file-test')
    @ipc_file = Adapters::IpcFile.new(data_dir: @data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && Dir.exist?(@data_dir)
  end

  def build_message(url: 'https://example.com', new_window: false)
    Domain::IpcMessage.new(url: url, timestamp: TIMESTAMP, new_window: new_window)
  end

  def test_writes_the_message_where_the_other_instance_looks_for_it
    @ipc_file.write(build_message)

    assert_equal File.join(@data_dir, 'pending-url'), @ipc_file.path
    assert File.exist?(@ipc_file.path)
  end

  def test_reads_back_the_message_that_was_written
    message = build_message(url: 'https://example.com/page', new_window: true)
    @ipc_file.write(message)

    assert_equal message, @ipc_file.read
  end

  def test_reads_nothing_when_no_request_is_pending
    assert_nil @ipc_file.read
  end

  def test_the_latest_request_replaces_the_previous_one
    @ipc_file.write(build_message(url: 'https://first.example'))
    @ipc_file.write(build_message(url: 'https://second.example'))

    assert_equal 'https://second.example', @ipc_file.read.url
  end

  def test_delete_clears_the_pending_request
    @ipc_file.write(build_message)
    @ipc_file.delete

    refute File.exist?(@ipc_file.path)
    assert_nil @ipc_file.read
  end

  def test_delete_is_harmless_when_nothing_is_pending
    @ipc_file.delete # does not raise

    assert_nil @ipc_file.read
  end

  def test_creates_its_directory_if_the_browser_has_never_run
    nested = File.join(@data_dir, 'never', 'used')
    ipc_file = Adapters::IpcFile.new(data_dir: nested)
    ipc_file.write(build_message)

    assert File.exist?(File.join(nested, 'pending-url'))
  end

  def test_a_urlless_new_window_request_survives_the_round_trip
    @ipc_file.write(build_message(url: '', new_window: true))

    message = @ipc_file.read
    refute message.url?
    assert message.new_window?
  end
end
