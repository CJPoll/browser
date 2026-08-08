require 'gtk3'
require_relative '../domain/download_controls'

# Sidebar view for displaying and managing downloads
#
# This is a UI Component: it renders Download domain objects and emits the
# user's intent through callbacks. It holds no manager, repository or WebKit
# object -- the Framework binds the callbacks to DownloadCoordinator and
# DownloadHandler.
class DownloadListView
  attr_reader :list_widget

  # Creates a new download list view
  #
  # @param callbacks [Hash] Data source and intent callbacks:
  #   - :get_downloads => -> { Array<Download> } newest first
  #   - :on_pause => ->(download_id) { } stop a running transfer
  #   - :on_resume => ->(download_id) { } restart a paused or failed transfer
  #   - :on_cancel => ->(download_id) { } abandon a transfer
  #   - :on_remove => ->(download_id) { } forget a finished download
  #   - :on_open_location => ->(destination) { } reveal the file
  def initialize(callbacks = {})
    @callbacks = callbacks
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single
  end

  # Refreshes the download list
  def refresh
    @list_widget.children.each { |child| @list_widget.remove(child) }

    downloads = @callbacks[:get_downloads]&.call || []

    if downloads.empty?
      label = Gtk::Label.new("No downloads")
      label.margin = 20
      @list_widget.add(label)
    else
      downloads.each { |download| @list_widget.add(create_download_row(download)) }
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

  private

  # Creates a row widget for a download entry
  #
  # @param download [Download] Download domain object
  # @return [Gtk::ListBoxRow] The row widget
  def create_download_row(download)
    row = Gtk::ListBoxRow.new
    row.instance_variable_set(:@download_id, download.id)

    vbox = Gtk::Box.new(:vertical, 4)
    vbox.margin = 8

    top_hbox = Gtk::Box.new(:horizontal, 8)

    filename_label = Gtk::Label.new(download.basename)
    filename_label.xalign = 0
    filename_label.ellipsize = :end
    top_hbox.pack_start(filename_label, expand: true, fill: true, padding: 0)

    control_buttons(download).each do |button|
      top_hbox.pack_start(button, expand: false, fill: false, padding: 0)
    end

    vbox.pack_start(top_hbox, expand: false, fill: false, padding: 0)

    if download.state == :pending || download.state == :in_progress
      vbox.pack_start(build_progress_bar(download, row), expand: false, fill: false, padding: 0)
    end

    status_label = Gtk::Label.new
    status_label.xalign = 0
    status_label.ellipsize = :end
    status_label.text = status_text(download)
    row.instance_variable_set(:@status_label, status_label)
    vbox.pack_start(status_label, expand: false, fill: false, padding: 0)

    row.add(vbox)
    row
  end

  # Buttons offered for a download, in display order
  #
  # Which controls appear is a domain decision (Domain::DownloadControls);
  # this method only turns the descriptors into widgets.
  #
  # @param download [Download] Download domain object
  # @return [Array<Gtk::Button>] Control buttons
  def control_buttons(download)
    Domain::DownloadControls.for(download).map do |control|
      intent_button(control, download)
    end
  end

  # Builds a button that reports one intent for a download
  #
  # @param control [Hash] Descriptor from Domain::DownloadControls
  # @param download [Download] Download the button acts on
  # @return [Gtk::Button] The button
  def intent_button(control, download)
    button = Gtk::Button.new(label: control[:label])
    button.tooltip_text = control[:tooltip]

    callback_name = :"on_#{control[:intent]}"
    argument = control[:intent] == :open_location ? download.destination : download.id

    button.signal_connect("clicked") do
      @callbacks[callback_name]&.call(argument)
      refresh unless control[:intent] == :open_location
    end

    button
  end

  def build_progress_bar(download, row)
    progress_bar = Gtk::ProgressBar.new

    if download.total_bytes && download.total_bytes > 0
      progress_bar.fraction = download.bytes_received.to_f / download.total_bytes
    else
      progress_bar.pulse
    end

    row.instance_variable_set(:@progress_bar, progress_bar)
    progress_bar
  end

  # Human-readable status line for a download
  #
  # @param download [Download] Download domain object
  # @return [String] Status text
  def status_text(download)
    case download.state
    when :completed
      "Completed - #{format_size(download.total_bytes || 0)}"
    when :failed
      "Failed: #{download.error_message || 'Unknown error'}"
    when :cancelled
      "Cancelled"
    when :paused
      "Paused - #{transferred_text(download)}"
    else
      transferred_text(download)
    end
  end

  def transferred_text(download)
    if download.total_bytes && download.total_bytes > 0
      "#{format_size(download.bytes_received)} / #{format_size(download.total_bytes)}"
    else
      "#{format_size(download.bytes_received)} downloaded"
    end
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
