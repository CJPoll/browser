require 'gtk3'

# Find bar for in-page text search
#
# Provides real-time text search in web pages with highlighting, navigation
# between results, and case-sensitive search option.
#
# Features:
# - Real-time search (2+ character minimum)
# - Highlight all matches in page
# - Navigate between results with buttons or Enter/Shift+Enter
# - Match count display ("3 of 15")
# - Case-sensitive toggle
# - ESC to close and clear highlights
#
# Thread Safety: All WebKit find operations are non-blocking (run in WebKit process).
# Signals (found-text, failed-to-find-text) are emitted on main thread.
class FindBar
  attr_reader :widget

  # Callbacks:
  # - :on_close => ->{} - Called when find bar is closed
  # - :get_current_tab => ->{ Tab } - Returns current tab
  def initialize(callbacks)
    @callbacks = callbacks
    @current_find_controller = nil
    @match_count = 0
    @current_match = 0

    create_widget
  end

  # Shows the find bar and focuses the search entry
  def show
    # Temporarily allow show_all to work (needed because no_show_all is set on widget)
    @widget.no_show_all = false
    @widget.show_all
    @widget.no_show_all = true
    @search_entry.grab_focus
  end

  # Hides the find bar and clears highlights
  def hide
    clear_search
    @widget.hide
  end

  # Returns true if find bar is visible
  def visible?
    @widget.visible?
  end

  private

  def create_widget
    # Action bar at bottom of window
    @widget = Gtk::ActionBar.new

    # Search entry
    @search_entry = Gtk::SearchEntry.new
    @search_entry.placeholder_text = "Find in page"
    @search_entry.width_chars = 30
    @widget.pack_start(@search_entry)

    # Match count label
    @match_label = Gtk::Label.new("")
    @match_label.margin_start = 8
    @match_label.margin_end = 8
    @widget.pack_start(@match_label)

    # Previous button
    @prev_button = Gtk::Button.new
    @prev_button.image = Gtk::Image.new(icon_name: "go-up-symbolic", size: :button)
    @prev_button.tooltip_text = "Previous match (Shift+Enter)"
    @prev_button.sensitive = false
    @widget.pack_start(@prev_button)

    # Next button
    @next_button = Gtk::Button.new
    @next_button.image = Gtk::Image.new(icon_name: "go-down-symbolic", size: :button)
    @next_button.tooltip_text = "Next match (Enter)"
    @next_button.sensitive = false
    @widget.pack_start(@next_button)

    # Case sensitive toggle
    @case_sensitive_button = Gtk::ToggleButton.new
    @case_sensitive_button.label = "Aa"
    @case_sensitive_button.tooltip_text = "Case sensitive"
    @case_sensitive_button.margin_start = 8
    @widget.pack_start(@case_sensitive_button)

    # Close button
    @close_button = Gtk::Button.new
    @close_button.image = Gtk::Image.new(icon_name: "window-close-symbolic", size: :button)
    @close_button.tooltip_text = "Close (ESC)"
    @close_button.relief = :none
    @widget.pack_end(@close_button)

    setup_signals
  end

  def setup_signals
    # Search entry: text changed
    @search_entry.signal_connect("changed") do
      perform_search
    end

    # Search entry: Enter key
    @search_entry.signal_connect("activate") do
      search_next
    end

    # Search entry: key press (for Shift+Enter)
    @search_entry.signal_connect("key-press-event") do |_widget, event|
      if event.keyval == Gdk::Keyval::KEY_Return && event.state.shift_mask?
        search_previous
        true  # Stop propagation
      elsif event.keyval == Gdk::Keyval::KEY_Escape
        hide
        @callbacks[:on_close].call if @callbacks[:on_close]
        true
      else
        false
      end
    end

    # Previous button
    @prev_button.signal_connect("clicked") do
      search_previous
    end

    # Next button
    @next_button.signal_connect("clicked") do
      search_next
    end

    # Case sensitive toggle
    @case_sensitive_button.signal_connect("toggled") do
      perform_search
    end

    # Close button
    @close_button.signal_connect("clicked") do
      hide
      @callbacks[:on_close].call if @callbacks[:on_close]
    end
  end

  def perform_search
    text = @search_entry.text
    tab = @callbacks[:get_current_tab].call
    return unless tab

    # Clear previous search
    if @current_find_controller
      @current_find_controller.search_finish
      @current_find_controller = nil
    end

    # Require minimum 2 characters
    if text.length < 2
      update_match_label(0, 0)
      @prev_button.sensitive = false
      @next_button.sensitive = false
      return
    end

    # Get find controller for current tab
    find_controller = tab.webview.find_controller
    @current_find_controller = find_controller

    # Set up signal handlers for this search
    setup_find_controller_signals(find_controller)

    # Build search options
    options = WebKit2Gtk::FindOptions::WRAP_AROUND
    unless @case_sensitive_button.active?
      options |= WebKit2Gtk::FindOptions::CASE_INSENSITIVE
    end

    # Start search (non-blocking, results come via signals)
    find_controller.search(text, options, 999)  # Max 999 matches to count
  end

  def setup_find_controller_signals(find_controller)
    # Remove old signal handlers if any
    # Note: GObject signal handlers are automatically disconnected when object is destroyed
    # For our use case, we create a new find_controller for each tab, so old handlers
    # won't interfere

    # Found matches signal
    find_controller.signal_connect("found-text") do |_controller, match_count|
      @match_count = match_count
      update_match_label(1, match_count)  # Start at first match
      @prev_button.sensitive = true
      @next_button.sensitive = true
    end

    # No matches found signal
    find_controller.signal_connect("failed-to-find-text") do
      @match_count = 0
      update_match_label(0, 0)
      @prev_button.sensitive = false
      @next_button.sensitive = false
    end

    # Count updated signal (emitted when search completes with total count)
    find_controller.signal_connect("counted-matches") do |_controller, count|
      @match_count = count
      # Update label but keep current match position
      update_match_label(@current_match, count) if @current_match > 0
    end
  end

  def search_next
    return unless @current_find_controller && @match_count > 0

    @current_find_controller.search_next
    # Update match position (wraps around)
    @current_match = @current_match < @match_count ? @current_match + 1 : 1
    update_match_label(@current_match, @match_count)
  end

  def search_previous
    return unless @current_find_controller && @match_count > 0

    @current_find_controller.search_previous
    # Update match position (wraps around)
    @current_match = @current_match > 1 ? @current_match - 1 : @match_count
    update_match_label(@current_match, @match_count)
  end

  def update_match_label(current, total)
    @current_match = current
    if total > 0
      @match_label.text = "#{current} of #{total}"
    else
      @match_label.text = "No matches"
    end
  end

  def clear_search
    if @current_find_controller
      @current_find_controller.search_finish
      @current_find_controller = nil
    end
    @search_entry.text = ""
    update_match_label(0, 0)
    @prev_button.sensitive = false
    @next_button.sensitive = false
  end
end
