require 'gtk3'

# Toolbar container managing navigation controls and URL bar
class Toolbar
  attr_reader :widget, :url_entry

  # Debounce delay for autocomplete (milliseconds)
  AUTOCOMPLETE_DEBOUNCE_MS = 150

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
    @autocomplete_callback = nil
    @autocomplete_popover = nil
    @debounce_timer = nil

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

    # Handle text changes for autocomplete (debounced)
    @url_entry.signal_connect("changed") do
      debounce_autocomplete
    end

    # Handle keyboard events in URL entry for autocomplete and navigation
    @url_entry.signal_connect("key-press-event") do |widget, event|
      handle_url_entry_key_press(event)
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

  # Sets the autocomplete callback
  #
  # @param callback [Proc] Callback that receives query text: ->(text) { ... }
  def on_autocomplete=(callback)
    @autocomplete_callback = callback
  end

  # Sets the autocomplete popover for keyboard handling
  #
  # @param popover [AutocompletePopover] The popover instance
  def autocomplete_popover=(popover)
    @autocomplete_popover = popover
  end

  private

  # Handles key press events in the URL entry
  #
  # @param event [Gdk::EventKey] Key press event
  # @return [Boolean] True if event was handled
  def handle_url_entry_key_press(event)
    case event.keyval
    when Gdk::Keyval::KEY_Escape
      handle_escape_key

    when Gdk::Keyval::KEY_Down
      # Navigate down in autocomplete popover
      if @autocomplete_popover&.visible?
        @autocomplete_popover.select_next
        true  # Event handled
      else
        false
      end

    when Gdk::Keyval::KEY_Up
      # Navigate up in autocomplete popover
      if @autocomplete_popover&.visible?
        @autocomplete_popover.select_previous
        true  # Event handled
      else
        false
      end

    when Gdk::Keyval::KEY_Tab
      # Tab confirms autocomplete selection and keeps focus
      if @autocomplete_popover&.visible? && @autocomplete_popover.current_selection
        selection = @autocomplete_popover.current_selection
        @url_entry.text = selection[:uri]
        @autocomplete_popover.hide
        # Keep cursor at end of text
        @url_entry.position = -1
        true  # Event handled
      else
        false
      end

    when Gdk::Keyval::KEY_Return, Gdk::Keyval::KEY_KP_Enter
      # Enter confirms autocomplete selection and navigates
      if @autocomplete_popover&.visible? && @autocomplete_popover.current_selection
        @autocomplete_popover.confirm_selection
        true  # Event handled - navigation is triggered by confirm_selection
      else
        false  # Let activate signal handle normal navigation
      end

    else
      false  # Let other handlers process
    end
  end

  # Handles Escape key: hide popover first, then restore URL and unfocus
  def handle_escape_key
    # If autocomplete popover is visible, hide it first
    if @autocomplete_popover&.visible?
      @autocomplete_popover.hide
      return true
    end

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
  end

  # Debounces autocomplete to avoid excessive calls while typing
  def debounce_autocomplete
    # Cancel previous timer if pending
    GLib::Source.remove(@debounce_timer) if @debounce_timer

    @debounce_timer = GLib::Timeout.add(AUTOCOMPLETE_DEBOUNCE_MS) do
      @autocomplete_callback&.call(@url_entry.text)
      @debounce_timer = nil
      false  # Don't repeat
    end
  end
end
