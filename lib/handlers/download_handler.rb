# frozen_string_literal: true

require_relative '../managers/download_coordinator'

# DownloadHandler connects WebKit download signals to the DownloadCoordinator.
#
# This is a UI/Handler layer component that:
# - Listens for WebKit download events
# - Delegates business logic to DownloadCoordinator
# - Does NOT call repository directly
# - Handles user interactions (cancel, open file, etc.)
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

    # Map WebKit::Download -> download_id for tracking
    @webkit_downloads = {}

    setup_download_signal
  end

  # Cancels a download
  #
  # @param download_id [Integer] Download ID to cancel
  # @return [Boolean] True if cancelled, false otherwise
  def cancel(download_id)
    download = @coordinator.cancel_download(download_id)
    return false unless download

    # Cancel the WebKit download if still active
    webkit_download = @webkit_downloads.key(download_id)
    webkit_download&.cancel

    true
  end

  # Gets all downloads
  #
  # @return [Array<Download>] All downloads
  def get_all_downloads
    @coordinator.get_all_downloads
  end

  # Gets active downloads
  #
  # @return [Array<Download>] Active downloads
  def get_active_downloads
    @coordinator.get_active_downloads
  end

  # Gets a specific download
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Download or nil
  def get_download(download_id)
    @coordinator.get_download(download_id)
  end

  # Deletes a download record
  #
  # @param download_id [Integer] Download ID
  # @return [Boolean] True if deleted
  def delete_download(download_id)
    @coordinator.delete_download(download_id)
  end

  private

  def setup_download_signal
    @web_context.signal_connect('download-started') do |_context, webkit_download|
      handle_download_started(webkit_download)
      false  # Allow download to proceed
    end
  end

  def handle_download_started(webkit_download)
    # Get suggested filename and default download directory
    request = webkit_download.request
    url = request.uri

    # Determine destination path
    destination = determine_destination(webkit_download)

    # Create download record via coordinator
    download = @coordinator.start_download(url, destination)

    # Track WebKit download -> ID mapping
    @webkit_downloads[webkit_download] = download.id

    # Set the destination on the WebKit download
    # WebKit expects file:// URI for destination
    webkit_download.destination = "file://#{download.destination}"

    # Connect progress signals
    setup_progress_signals(webkit_download, download.id)

    # Notify listener
    @on_download_started&.call(download)
  end

  def setup_progress_signals(webkit_download, download_id)
    # Progress updates
    webkit_download.signal_connect('received-data') do |_download, _data_length|
      handle_progress(webkit_download, download_id)
    end

    # Completion
    webkit_download.signal_connect('finished') do |_download|
      handle_finished(download_id)
    end

    # Failure
    webkit_download.signal_connect('failed') do |_download, error|
      handle_failed(download_id, error)
    end
  end

  def handle_progress(webkit_download, download_id)
    bytes_received = webkit_download.received_data_length
    # WebKit provides estimated total, may be -1 if unknown
    response = webkit_download.response
    total_bytes = response&.content_length
    total_bytes = nil if total_bytes && total_bytes < 0

    download = @coordinator.update_progress(
      download_id,
      bytes_received: bytes_received,
      total_bytes: total_bytes
    )

    @on_download_progress&.call(download) if download
  end

  def handle_finished(download_id)
    download = @coordinator.mark_completed(download_id)

    # Cleanup tracking
    @webkit_downloads.delete_if { |_k, v| v == download_id }

    @on_download_finished&.call(download) if download
  end

  def handle_failed(download_id, error)
    error_message = error&.message || 'Unknown error'
    download = @coordinator.mark_failed(download_id, error_message)

    # Cleanup tracking
    @webkit_downloads.delete_if { |_k, v| v == download_id }

    @on_download_failed&.call(download) if download
  end

  def determine_destination(webkit_download)
    # Get suggested filename from WebKit
    suggested_filename = webkit_download.response&.suggested_filename
    suggested_filename ||= File.basename(URI.parse(webkit_download.request.uri).path)
    suggested_filename = 'download' if suggested_filename.nil? || suggested_filename.empty?

    # Use XDG download directory or ~/Downloads
    download_dir = ENV['XDG_DOWNLOAD_DIR'] ||
                   File.join(Dir.home, 'Downloads')

    # Ensure directory exists
    FileUtils.mkdir_p(download_dir) unless Dir.exist?(download_dir)

    File.join(download_dir, suggested_filename)
  end
end
