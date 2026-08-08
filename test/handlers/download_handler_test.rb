require 'minitest/autorun'
require_relative '../../lib/domain/download'
require_relative '../../lib/handlers/download_handler'

# Minimal stand-ins for the WebKit objects the handler talks to. They only
# implement the handful of methods DownloadHandler actually uses.
module FakeSignals
  def signal_connect(name, &block)
    signal_handlers[name] = block
  end

  def emit(name, *args)
    handler = signal_handlers[name]
    handler&.call(self, *args)
  end

  def signal_handlers
    @signal_handlers ||= {}
  end
end

class FakeRequest
  attr_reader :uri

  def initialize(uri)
    @uri = uri
  end
end

class FakeResponse
  attr_reader :suggested_filename, :content_length

  def initialize(suggested_filename: nil, content_length: -1)
    @suggested_filename = suggested_filename
    @content_length = content_length
  end
end

class FakeWebKitDownload
  include FakeSignals

  attr_reader :request, :response, :destination, :received_data_length

  def initialize(uri, suggested_filename: 'file.pdf', content_length: -1)
    @request = FakeRequest.new(uri)
    @response = FakeResponse.new(
      suggested_filename: suggested_filename,
      content_length: content_length
    )
    @received_data_length = 0
    @cancelled = false
  end

  def destination=(value)
    @destination = value
  end

  def cancel
    @cancelled = true
    # WebKit reports a user cancellation as a failure.
    emit('failed', FakeError.new('Cancelled by user'))
  end

  def cancelled?
    @cancelled
  end

  def receive(bytes)
    @received_data_length = bytes
    emit('received-data', bytes)
  end
end

class FakeError
  attr_reader :message

  def initialize(message)
    @message = message
  end
end

class FakeWebContext
  include FakeSignals

  attr_reader :requested_uris

  def initialize
    @requested_uris = []
  end

  def download_uri(uri)
    @requested_uris << uri
    download = FakeWebKitDownload.new(uri)
    emit('download-started', download)
    download
  end
end

# Records what the handler asked the Manager to do.
class SpyCoordinator
  CREATED_AT = Time.at(1_700_000_000).freeze

  attr_reader :calls

  def initialize
    @calls = []
    @downloads = {}
    @next_id = 1
  end

  def start_download(url, destination)
    @calls << [:start_download, url, destination]
    download = Download.new(
      id: @next_id,
      url: url,
      destination: destination,
      created_at: CREATED_AT
    )
    @next_id += 1
    @downloads[download.id] = download
  end

  def update_progress(id, bytes_received:, total_bytes: nil)
    @calls << [:update_progress, id, bytes_received, total_bytes]
    store(@downloads[id]&.with(bytes_received: bytes_received, total_bytes: total_bytes))
  end

  def mark_completed(id)
    @calls << [:mark_completed, id]
    store(@downloads[id]&.mark_completed(now: CREATED_AT))
  end

  def mark_failed(id, message)
    @calls << [:mark_failed, id, message]
    store(@downloads[id]&.mark_failed(message, now: CREATED_AT))
  end

  def cancel_download(id)
    @calls << [:cancel_download, id]
    store(@downloads[id]&.mark_cancelled(now: CREATED_AT))
  end

  def pause_download(id)
    @calls << [:pause_download, id]
    store(@downloads[id]&.mark_paused)
  end

  def resume_download(id)
    @calls << [:resume_download, id]
    store(@downloads[id]&.mark_resumed(now: CREATED_AT))
  end

  def find(id)
    @downloads[id]
  end

  def called?(name)
    @calls.any? { |call| call.first == name }
  end

  private

  def store(download)
    return nil unless download

    @downloads[download.id] = download
  end
end

class DownloadHandlerTest < Minitest::Test
  def setup
    @web_context = FakeWebContext.new
    @coordinator = SpyCoordinator.new
    @started = []
    @finished = []
    @failed = []

    @handler = DownloadHandler.new(
      @web_context,
      @coordinator,
      on_download_started: ->(download) { @started << download },
      on_download_finished: ->(download) { @finished << download },
      on_download_failed: ->(download) { @failed << download }
    )
  end

  def start_download(uri = 'https://example.com/file.pdf')
    webkit_download = FakeWebKitDownload.new(uri)
    @web_context.emit('download-started', webkit_download)
    webkit_download
  end

  def test_a_started_download_is_recorded_and_given_a_destination
    webkit_download = start_download

    assert @coordinator.called?(:start_download)
    assert_equal 1, @started.length
    assert_equal "file://#{@started.first.destination}", webkit_download.destination
  end

  def test_progress_is_forwarded_to_the_coordinator
    webkit_download = start_download

    webkit_download.receive(512)

    assert @coordinator.called?(:update_progress)
    assert_equal 512, @coordinator.find(1).bytes_received
  end

  def test_completion_is_forwarded_to_the_coordinator
    webkit_download = start_download

    webkit_download.emit('finished')

    assert_equal :completed, @coordinator.find(1).state
    assert_equal 1, @finished.length
  end

  def test_failure_is_forwarded_to_the_coordinator
    webkit_download = start_download

    webkit_download.emit('failed', FakeError.new('Connection reset'))

    assert_equal :failed, @coordinator.find(1).state
    assert_equal 'Connection reset', @coordinator.find(1).error_message
    assert_equal 1, @failed.length
  end

  def test_pause_stops_the_transfer_and_records_the_pause
    webkit_download = start_download

    @handler.pause(1)

    assert webkit_download.cancelled?, "The WebKit transfer must actually stop"
    assert_equal :paused, @coordinator.find(1).state
  end

  def test_pause_is_not_overwritten_by_the_cancellation_failure
    # Cancelling a WebKit download emits 'failed'. That failure is ours, not
    # the network's, so it must not turn the paused record into a failed one.
    start_download

    @handler.pause(1)

    assert_equal :paused, @coordinator.find(1).state
    refute @coordinator.called?(:mark_failed)
    assert_empty @failed
  end

  def test_cancel_stops_the_transfer_and_records_the_cancellation
    webkit_download = start_download

    @handler.cancel(1)

    assert webkit_download.cancelled?
    assert_equal :cancelled, @coordinator.find(1).state
    refute @coordinator.called?(:mark_failed)
  end

  def test_resume_starts_a_fresh_transfer_for_the_same_record
    start_download
    @handler.pause(1)

    @handler.resume(1)

    assert_equal ['https://example.com/file.pdf'], @web_context.requested_uris
    assert_equal :in_progress, @coordinator.find(1).state
  end

  def test_resume_does_not_create_a_second_download_record
    start_download
    @handler.pause(1)

    @handler.resume(1)

    start_calls = @coordinator.calls.count { |call| call.first == :start_download }
    assert_equal 1, start_calls, "The resumed transfer reuses the existing record"
  end

  def test_resume_reuses_the_original_destination
    start_download
    original_destination = @coordinator.find(1).destination
    @handler.pause(1)

    @handler.resume(1)

    assert_equal original_destination, @coordinator.find(1).destination
  end

  def test_resume_of_an_unknown_download_does_nothing
    assert_nil @handler.resume(999)
    assert_empty @web_context.requested_uris
  end

  def test_an_unrelated_download_does_not_steal_the_resumed_record
    # The adoption window is exactly one 'download-started' event, and it only
    # applies to a download of the same URL.
    start_download
    @handler.pause(1)
    @handler.resume(1)

    start_download('https://example.com/other.pdf')

    start_calls = @coordinator.calls.count { |call| call.first == :start_download }
    assert_equal 2, start_calls
  end
end
