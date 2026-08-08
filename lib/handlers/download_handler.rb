# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'uri'

# DownloadHandler connects WebKit download signals to the DownloadCoordinator.
#
# This is a Framework component that:
# - Owns the WebKit download objects and the signal wiring
# - Delegates every state decision to DownloadCoordinator
# - Does NOT call a repository or hold any persistence logic
# - Reports progress to its owner through callbacks
#
# Pause and resume: WebKit cannot suspend a transfer. Pausing therefore
# cancels the WebKit download and records :paused; resuming starts a fresh
# transfer to the same destination and reuses the existing record.
#
# Thread Safety: All WebKit callbacks run on the GTK main thread.
class DownloadHandler
  # Creates a new DownloadHandler
  #
  # @param web_context [WebKit2Gtk::WebContext] WebKit context to monitor
  # @param coordinator [DownloadCoordinator] Coordinator for download operations
  # @param on_download_started [Proc, nil] Callback when download starts ->(download) {}
  # @param on_download_progress [Proc, nil] Callback for progress updates ->(download) {}
  # @param on_download_finished [Proc, nil] Callback when download completes ->(download) {}
  # @param on_download_failed [Proc, nil] Callback when download fails ->(download) {}
  def initialize(web_context, coordinator,
                 on_download_started: nil,
                 on_download_progress: nil,
                 on_download_finished: nil,
                 on_download_failed: nil)
    @web_context = web_context
    @coordinator = coordinator
    @on_download_started = on_download_started
    @on_download_progress = on_download_progress
    @on_download_finished = on_download_finished
    @on_download_failed = on_download_failed

    # download_id => WebKit2Gtk::Download, for pause/resume/cancel
    @webkit_downloads = {}

    # IDs we stopped on purpose. WebKit reports a cancelled transfer as a
    # failure, and that failure must not overwrite the state we just recorded.
    @intentionally_stopped = Set.new

    # A record waiting to be attached to the next matching download-started
    # event, set while a resume is in flight.
    @record_awaiting_transfer = nil

    setup_download_signal
  end

  # Cancels a download
  #
  # @param download_id [Integer] Download ID to cancel
  # @return [Download, nil] The cancelled download, or nil if it could not be cancelled
  def cancel(download_id)
    record_transition(download_id) { @coordinator.cancel_download(download_id) }
  end

  # Pauses a download
  #
  # @param download_id [Integer] Download ID to pause
  # @return [Download, nil] The paused download, or nil if it could not be paused
  def pause(download_id)
    record_transition(download_id) { @coordinator.pause_download(download_id) }
  end

  # Resumes (or retries) a download by starting a fresh transfer
  #
  # @param download_id [Integer] Download ID to resume
  # @return [Download, nil] The restarted download, or nil if it could not be resumed
  def resume(download_id)
    download = @coordinator.resume_download(download_id)
    return nil unless download

    @record_awaiting_transfer = download
    @web_context.download_uri(download.url)

    download
  end

  private

  # Applies a coordinator transition and stops the underlying transfer.
  def record_transition(download_id)
    download = yield
    return nil unless download

    stop_transfer(download_id)
    download
  end

  def stop_transfer(download_id)
    webkit_download = @webkit_downloads.delete(download_id)
    return unless webkit_download

    @intentionally_stopped << download_id
    webkit_download.cancel
  end

  def setup_download_signal
    @web_context.signal_connect('download-started') do |_context, webkit_download|
      handle_download_started(webkit_download)
      false  # Allow download to proceed
    end
  end

  def handle_download_started(webkit_download)
    url = webkit_download.request.uri

    download = claim_awaiting_record(url) ||
               @coordinator.start_download(url, determine_destination(webkit_download))

    @webkit_downloads[download.id] = webkit_download

    # WebKit expects a file:// URI for the destination
    webkit_download.destination = "file://#{download.destination}"

    setup_progress_signals(webkit_download, download.id)

    @on_download_started&.call(download)
  end

  # Attaches a resumed record to the transfer it asked for.
  #
  # The window is a single download-started event, and the URL must match, so
  # an unrelated download starting in between cannot claim the record.
  def claim_awaiting_record(url)
    record = @record_awaiting_transfer
    @record_awaiting_transfer = nil

    return nil unless record && record.url == url

    record
  end

  def setup_progress_signals(webkit_download, download_id)
    webkit_download.signal_connect('received-data') do |_download, _data_length|
      handle_progress(webkit_download, download_id)
    end

    webkit_download.signal_connect('finished') do |_download|
      handle_finished(download_id)
    end

    webkit_download.signal_connect('failed') do |_download, error|
      handle_failed(download_id, error)
    end
  end

  def handle_progress(webkit_download, download_id)
    bytes_received = webkit_download.received_data_length
    # WebKit provides an estimated total, which may be -1 if unknown
    total_bytes = webkit_download.response&.content_length
    total_bytes = nil if total_bytes && total_bytes < 0

    download = @coordinator.update_progress(
      download_id,
      bytes_received: bytes_received,
      total_bytes: total_bytes
    )

    @on_download_progress&.call(download) if download
  end

  def handle_finished(download_id)
    @intentionally_stopped.delete(download_id)
    @webkit_downloads.delete(download_id)

    download = @coordinator.mark_completed(download_id)
    @on_download_finished&.call(download) if download
  end

  def handle_failed(download_id, error)
    # A transfer we stopped ourselves already has its state recorded.
    return if @intentionally_stopped.delete?(download_id)

    @webkit_downloads.delete(download_id)

    error_message = error&.message || 'Unknown error'
    download = @coordinator.mark_failed(download_id, error_message)

    @on_download_failed&.call(download) if download
  end

  def determine_destination(webkit_download)
    suggested_filename = webkit_download.response&.suggested_filename
    suggested_filename ||= File.basename(URI.parse(webkit_download.request.uri).path)
    suggested_filename = 'download' if suggested_filename.nil? || suggested_filename.empty?

    download_dir = ENV['XDG_DOWNLOAD_DIR'] || File.join(Dir.home, 'Downloads')
    FileUtils.mkdir_p(download_dir) unless Dir.exist?(download_dir)

    File.join(download_dir, suggested_filename)
  end
end
