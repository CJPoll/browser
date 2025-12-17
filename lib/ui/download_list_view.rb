require 'gtk3'

# Sidebar view for displaying and managing downloads
class DownloadListView
  attr_reader :list_widget, :download_manager

  # Creates a new download list view
  #
  # @param download_manager [DownloadManager] Download manager for querying downloads
  def initialize(download_manager)
    @download_manager = download_manager
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Track download objects by ID for pause/resume/cancel operations
    # Map of download_id => WebKit2Gtk::Download
    @download_objects = {}

    # Callback invoked when "Open File Location" is clicked
    # Signature: ->(filepath) { ... }
    @on_open_location = nil

    # Callback invoked when "Retry" is clicked
    # Signature: ->(url, filename) { ... }
    @on_retry = nil
  end

  # Sets callback to invoke when open location is clicked
  #
  # @param callback [Proc] Callback proc accepting filepath: ->(filepath) { ... }
  # @return [void]
  def on_open_location=(callback)
    @on_open_location = callback
  end

  # Sets callback to invoke when retry is clicked
  #
  # @param callback [Proc] Callback proc accepting url and filename: ->(url, filename) { ... }
  # @return [void]
  def on_retry=(callback)
    @on_retry = callback
  end

  # Registers a WebKit download object for control operations
  #
  # @param download_id [Integer] Database ID
  # @param download [WebKit2Gtk::Download] WebKit download object
  def register_download(download_id, download)
    @download_objects[download_id] = download
  end

  # Unregisters a download object (when completed/cancelled/failed)
  #
  # @param download_id [Integer] Database ID
  def unregister_download(download_id)
    @download_objects.delete(download_id)
  end

  # Refreshes the download list
  def refresh
    # Clear existing rows
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Get all downloads from manager
    downloads = @download_manager.all

    if downloads.empty?
      # Show "No downloads" message
      label = Gtk::Label.new("No downloads")
      label.margin = 20
      @list_widget.add(label)
    else
      downloads.each do |download|
        row = create_download_row(download)
        @list_widget.add(row)
      end
    end

    @list_widget.show_all
  end

  # Updates progress for a specific download
  #
  # @param download_id [Integer] Download ID
  # @param downloaded_size [Integer] Bytes downloaded
  # @param total_size [Integer] Total file size
  # @param speed [Float] Download speed in bytes/sec
  def update_progress(download_id, downloaded_size, total_size, speed)
    # Find the row for this download
    @list_widget.children.each do |row|
      next unless row.instance_variable_defined?(:@download_id)
      next unless row.instance_variable_get(:@download_id) == download_id

      progress_bar = row.instance_variable_get(:@progress_bar)
      status_label = row.instance_variable_get(:@status_label)

      if progress_bar && total_size && total_size > 0
        fraction = downloaded_size.to_f / total_size
        progress_bar.fraction = fraction

        # Calculate ETA
        if speed > 0
          remaining_bytes = total_size - downloaded_size
          eta_seconds = remaining_bytes / speed
          eta_text = format_time(eta_seconds)
          speed_text = format_size(speed)

          status_label.text = "#{format_size(downloaded_size)} / #{format_size(total_size)} - #{speed_text}/s - #{eta_text} remaining"
        else
          status_label.text = "#{format_size(downloaded_size)} / #{format_size(total_size)}"
        end
      elsif progress_bar
        progress_bar.pulse
        status_label.text = "#{format_size(downloaded_size)} downloaded"
      end

      break
    end
  end

  # Updates the state of a download row
  #
  # @param download_id [Integer] Download ID
  # @param state [String] New state
  def update_state(download_id, state)
    refresh  # For now, just refresh the whole list
  end

  private

  # Creates a row widget for a download entry
  #
  # @param download [Hash] Download entry from database
  # @return [Gtk::ListBoxRow] The row widget
  def create_download_row(download)
    row = Gtk::ListBoxRow.new
    row.instance_variable_set(:@download_id, download['id'])

    vbox = Gtk::Box.new(:vertical, 4)
    vbox.margin = 8

    # Top row: filename and controls
    top_hbox = Gtk::Box.new(:horizontal, 8)

    filename_label = Gtk::Label.new(download['filename'])
    filename_label.xalign = 0
    filename_label.ellipsize = :end
    top_hbox.pack_start(filename_label, expand: true, fill: true, padding: 0)

    # Control buttons based on state
    state = download['state']
    if state == DownloadManager::STATES[:active] || state == DownloadManager::STATES[:pending]
      # Pause button
      pause_btn = Gtk::Button.new(label: "⏸")
      pause_btn.tooltip_text = "Pause"
      pause_btn.signal_connect("clicked") do
        download_obj = @download_objects[download['id']]
        download_obj&.cancel  # WebKit doesn't have pause, so we cancel for now
        @download_manager.update_state(download['id'], DownloadManager::STATES[:paused])
        refresh
      end
      top_hbox.pack_start(pause_btn, expand: false, fill: false, padding: 0)

      # Cancel button
      cancel_btn = Gtk::Button.new(label: "✕")
      cancel_btn.tooltip_text = "Cancel"
      cancel_btn.signal_connect("clicked") do
        download_obj = @download_objects[download['id']]
        download_obj&.cancel
        @download_manager.update_state(download['id'], DownloadManager::STATES[:cancelled])
        refresh
      end
      top_hbox.pack_start(cancel_btn, expand: false, fill: false, padding: 0)

    elsif state == DownloadManager::STATES[:paused]
      # Resume button (note: WebKit doesn't support resume, so this will retry)
      resume_btn = Gtk::Button.new(label: "▶")
      resume_btn.tooltip_text = "Resume (re-downloads)"
      resume_btn.signal_connect("clicked") do
        @on_retry&.call(download['url'], download['filename'])
        refresh
      end
      top_hbox.pack_start(resume_btn, expand: false, fill: false, padding: 0)

      # Cancel button
      cancel_btn = Gtk::Button.new(label: "✕")
      cancel_btn.tooltip_text = "Cancel"
      cancel_btn.signal_connect("clicked") do
        @download_manager.update_state(download['id'], DownloadManager::STATES[:cancelled])
        refresh
      end
      top_hbox.pack_start(cancel_btn, expand: false, fill: false, padding: 0)

    elsif state == DownloadManager::STATES[:failed]
      # Retry button
      retry_btn = Gtk::Button.new(label: "↻")
      retry_btn.tooltip_text = "Retry"
      retry_btn.signal_connect("clicked") do
        @on_retry&.call(download['url'], download['filename'])
        refresh
      end
      top_hbox.pack_start(retry_btn, expand: false, fill: false, padding: 0)

      # Remove button
      remove_btn = Gtk::Button.new(label: "✕")
      remove_btn.tooltip_text = "Remove"
      remove_btn.signal_connect("clicked") do
        @download_manager.remove(download['id'])
        refresh
      end
      top_hbox.pack_start(remove_btn, expand: false, fill: false, padding: 0)

    elsif state == DownloadManager::STATES[:completed]
      # Open location button
      open_btn = Gtk::Button.new(label: "📁")
      open_btn.tooltip_text = "Open File Location"
      open_btn.signal_connect("clicked") do
        @on_open_location&.call(download['filepath'])
      end
      top_hbox.pack_start(open_btn, expand: false, fill: false, padding: 0)

      # Remove button
      remove_btn = Gtk::Button.new(label: "✕")
      remove_btn.tooltip_text = "Remove"
      remove_btn.signal_connect("clicked") do
        @download_manager.remove(download['id'])
        refresh
      end
      top_hbox.pack_start(remove_btn, expand: false, fill: false, padding: 0)

    elsif state == DownloadManager::STATES[:cancelled]
      # Remove button
      remove_btn = Gtk::Button.new(label: "✕")
      remove_btn.tooltip_text = "Remove"
      remove_btn.signal_connect("clicked") do
        @download_manager.remove(download['id'])
        refresh
      end
      top_hbox.pack_start(remove_btn, expand: false, fill: false, padding: 0)
    end

    vbox.pack_start(top_hbox, expand: false, fill: false, padding: 0)

    # Progress bar (only for active/pending downloads)
    if state == DownloadManager::STATES[:active] || state == DownloadManager::STATES[:pending]
      progress_bar = Gtk::ProgressBar.new
      if download['total_size'] && download['total_size'] > 0
        progress_bar.fraction = download['downloaded_size'].to_f / download['total_size']
      else
        progress_bar.pulse
      end
      row.instance_variable_set(:@progress_bar, progress_bar)
      vbox.pack_start(progress_bar, expand: false, fill: false, padding: 0)
    end

    # Status label
    status_label = Gtk::Label.new
    status_label.xalign = 0
    status_label.ellipsize = :end

    case state
    when DownloadManager::STATES[:completed]
      status_label.text = "Completed - #{format_size(download['total_size'] || 0)}"
    when DownloadManager::STATES[:failed]
      status_label.text = "Failed: #{download['error'] || 'Unknown error'}"
    when DownloadManager::STATES[:cancelled]
      status_label.text = "Cancelled"
    when DownloadManager::STATES[:paused]
      status_label.text = "Paused - #{format_size(download['downloaded_size'])} / #{format_size(download['total_size'])}"
    when DownloadManager::STATES[:active], DownloadManager::STATES[:pending]
      if download['total_size'] && download['total_size'] > 0
        status_label.text = "#{format_size(download['downloaded_size'])} / #{format_size(download['total_size'])}"
      else
        status_label.text = "#{format_size(download['downloaded_size'])} downloaded"
      end
    end

    row.instance_variable_set(:@status_label, status_label)
    vbox.pack_start(status_label, expand: false, fill: false, padding: 0)

    row.add(vbox)
    row
  end

  # Formats byte size to human-readable format
  #
  # @param bytes [Integer] Size in bytes
  # @return [String] Formatted size
  def format_size(bytes)
    return "0 B" if bytes.nil? || bytes == 0

    units = ['B', 'KB', 'MB', 'GB', 'TB']
    size = bytes.to_f
    unit_index = 0

    while size >= 1024 && unit_index < units.length - 1
      size /= 1024.0
      unit_index += 1
    end

    if unit_index == 0
      "#{size.to_i} #{units[unit_index]}"
    else
      "%.1f #{units[unit_index]}" % size
    end
  end

  # Formats seconds to human-readable time
  #
  # @param seconds [Float] Time in seconds
  # @return [String] Formatted time
  def format_time(seconds)
    return "Unknown" if seconds.nil? || seconds.infinite? || seconds.nan?

    if seconds < 60
      "#{seconds.to_i}s"
    elsif seconds < 3600
      minutes = (seconds / 60).to_i
      "#{minutes}m"
    else
      hours = (seconds / 3600).to_i
      "#{hours}h"
    end
  end
end
