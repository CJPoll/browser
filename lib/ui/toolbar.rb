require 'gtk3'

# Toolbar container managing navigation controls and URL bar
class Toolbar
  attr_reader :widget, :url_entry

  # Creates a new toolbar
  #
  # @param callbacks [Hash] Hash of callback procs:
  #   - :on_sidebar_toggle => -> { ... }
  #   - :on_back => -> { ... }
  #   - :on_forward => -> { ... }
  #   - :on_load_url => -> { ... }
  #   - :on_reader_toggle => -> { ... }
  #   - :on_downloads_toggle => -> { ... }
  #   - :get_current_tab => -> { Tab or nil }
  #   - :in_zen_mode => -> { true/false }
  #   - :get_download_state => -> { :none, :active, :paused, :failed }
  def initialize(callbacks)
    @callbacks = callbacks

    # Create toolbar box
    @widget = Gtk::Box.new(:horizontal, 5)
    @widget.margin_top = 5
    @widget.margin_bottom = 5
    @widget.margin_start = 5
    @widget.margin_end = 5

    # Sidebar toggle button
    sidebar_toggle = Gtk::Button.new(label: "☰")
    sidebar_toggle.signal_connect("clicked") { @callbacks[:on_sidebar_toggle].call }
    @widget.pack_start(sidebar_toggle, expand: false, fill: false, padding: 0)

    # Back button
    back_button = Gtk::Button.new(label: "⬅")
    back_button.signal_connect("clicked") { @callbacks[:on_back].call }
    @widget.pack_start(back_button, expand: false, fill: false, padding: 0)

    # Forward button
    forward_button = Gtk::Button.new(label: "➡")
    forward_button.signal_connect("clicked") { @callbacks[:on_forward].call }
    @widget.pack_start(forward_button, expand: false, fill: false, padding: 0)

    # Reader mode button
    @reader_button = Gtk::Button.new(label: "📖")
    @reader_button.tooltip_text = "Reader Mode"
    @reader_button.signal_connect("clicked") { @callbacks[:on_reader_toggle]&.call }
    @widget.pack_start(@reader_button, expand: false, fill: false, padding: 0)

    # Downloads button
    @downloads_button = Gtk::Button.new(label: "⬇")
    @downloads_button.tooltip_text = "Downloads"
    @downloads_button.signal_connect("clicked") { @callbacks[:on_downloads_toggle]&.call }
    @widget.pack_start(@downloads_button, expand: false, fill: false, padding: 0)

    # URL entry
    @url_entry = Gtk::Entry.new
    @url_entry.text = "https://www.example.com"
    @url_entry.signal_connect("activate") { @callbacks[:on_load_url].call }

    # Handle ESC key in URL entry
    @url_entry.signal_connect("key-press-event") do |widget, event|
      if event.keyval == Gdk::Keyval::KEY_Escape
        # Restore current tab's URL
        current_tab = @callbacks[:get_current_tab].call
        if current_tab && current_tab.webview.uri
          @url_entry.text = current_tab.webview.uri
        end

        # In zen mode, hide toolbar after ESC
        if @callbacks[:in_zen_mode].call
          @widget.hide
        end

        # Remove focus from URL entry
        current_tab.webview.grab_focus if current_tab

        true  # Event handled
      else
        false  # Let other handlers process
      end
    end

    @widget.pack_start(@url_entry, expand: true, fill: true, padding: 0)

    # Go button
    go_button = Gtk::Button.new(label: "Go")
    go_button.signal_connect("clicked") { @callbacks[:on_load_url].call }
    @widget.pack_start(go_button, expand: false, fill: false, padding: 0)
  end

  # Shows the toolbar widget
  def show
    @widget.show_all
  end

  # Hides the toolbar widget
  def hide
    @widget.hide
  end

  # Updates the URL entry text
  #
  # @param url [String] The URL to display
  def update_url(url)
    @url_entry.text = url if url
  end

  # Updates the download button badge/state
  #
  # @param state [Symbol] Download state (:none, :active, :paused, :failed)
  # @param count [Integer] Number of active downloads (optional)
  def update_download_badge(state, count = 0)
    case state
    when :active
      @downloads_button.label = count > 0 ? "⬇ #{count}" : "⬇"
    when :paused
      @downloads_button.label = "⏸"
    when :failed
      @downloads_button.label = "⬇ !"
    else
      @downloads_button.label = "⬇"
    end
  end
end
