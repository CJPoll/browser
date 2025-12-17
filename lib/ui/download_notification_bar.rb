require 'gtk3'

# Notification bar for completed downloads
# Shows at top of web view with "Open" and "Show in Folder" buttons
class DownloadNotificationBar
  attr_reader :widget

  # Creates a new download notification bar
  #
  # @param on_open [Proc] Callback when "Open" is clicked
  # @param on_show_folder [Proc] Callback when "Show in Folder" is clicked
  # @param on_dismiss [Proc] Callback when "Dismiss" is clicked
  def initialize(on_open:, on_show_folder:, on_dismiss:)
    @on_open = on_open
    @on_show_folder = on_show_folder
    @on_dismiss = on_dismiss
    @filepath = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Green background via CSS for success
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .download-notification-bar {
        background-color: #d4edda;
        border-bottom: 1px solid #28a745;
      }
      .download-notification-label {
        color: #155724;
        padding: 8px;
      }
      .download-notification-button {
        margin: 4px;
      }
    CSS

    # Add to default screen so CSS works
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('download-notification-bar')

    # Inner box for content
    box = Gtk::Box.new(:horizontal, 8)
    box.margin = 4
    @widget.add(box)

    # Message label
    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.style_context.add_class('download-notification-label')
    box.pack_start(@label, expand: true, fill: true, padding: 0)

    # Open button
    open_button = Gtk::Button.new(label: "Open")
    open_button.style_context.add_class('download-notification-button')
    open_button.signal_connect("clicked") do
      @on_open.call(@filepath) if @filepath && @on_open
      destroy
    end
    box.pack_start(open_button, expand: false, fill: false, padding: 0)

    # Show in Folder button
    show_folder_button = Gtk::Button.new(label: "Show in Folder")
    show_folder_button.style_context.add_class('download-notification-button')
    show_folder_button.signal_connect("clicked") do
      @on_show_folder.call(@filepath) if @filepath && @on_show_folder
      destroy
    end
    box.pack_start(show_folder_button, expand: false, fill: false, padding: 0)

    # Dismiss button
    dismiss_button = Gtk::Button.new(label: "Dismiss")
    dismiss_button.style_context.add_class('download-notification-button')
    dismiss_button.signal_connect("clicked") do
      @on_dismiss.call if @on_dismiss
      destroy
    end
    box.pack_start(dismiss_button, expand: false, fill: false, padding: 0)
  end

  # Sets the download file and updates the UI
  #
  # @param filename [String] Downloaded filename
  # @param filepath [String] Full path to downloaded file
  # @return [void]
  def set_download(filename, filepath)
    @filepath = filepath
    # Use Pango markup for reliable text color
    @label.markup = "<span foreground='#155724'>Download completed: #{filename}</span>"
  end

  # Destroys the notification bar
  #
  # @return [void]
  def destroy
    @widget.destroy
  end
end
