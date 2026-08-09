require 'gtk3'

# Handles all keyboard shortcuts and event routing
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
# All callbacks are expected to run synchronously on the main thread.
#
# Design Rationale: Uses case statements for key routing instead of mapping tables.
# Case statements are idiomatic Ruby for event routing, provide inline documentation,
# and handle conditional shortcuts (queue sidebar mode, zen mode) naturally.
# See "Standards Compliance and Design Rationale" section in spec for full justification.
class KeyboardHandler
  # Creates a new keyboard handler
  #
  # @param callbacks [Hash] Hash of callback proc groups:
  #   - :toolbar_actions => { focus_url_entry:, show_toolbar:, in_zen_mode: }
  #   - :sidebar_actions => { toggle:, show_tabs:, show_history:, show_queue:, show_downloads:, visible:, mode: }
  #   - :tab_actions => { create:, close_current:, next:, previous:, move_up:, move_down:, get_current: }
  #   - :navigation_actions => { go_back:, go_forward:, reload: }
  #   - :queue_actions => { add_current:, remove_and_next:, next_item:, previous_item:, move_current_up:, move_current_down: }
  #   - :zoom_actions => { zoom_in:, zoom_out:, reset: }
  #   - :mode_actions => { toggle_dark_mode:, toggle_zen_mode:, toggle_inspector: }
  #   - :window_actions => { reload_browser:, open_new_window:, open_video_popout:, open_site_permissions:, open_file: }
  #   - :find_actions => { show_find_bar: }
  #   - :markdown_actions => { toggle_source:, add_pdf_bookmarks: }
  # @raise [ArgumentError] if required callback groups or keys are missing
  def initialize(callbacks)
    validate_callbacks(callbacks)
    @callbacks = callbacks
  end

  # Handles key-press-event
  #
  # @param widget [Gtk::Widget] The widget that received the event
  # @param event [Gdk::EventKey] The key press event
  # @return [Boolean] true if event handled, false otherwise
  def handle_key_press(widget, event)
    # Check modifier combinations in priority order
    if event.state.control_mask? && event.state.shift_mask?
      handle_ctrl_shift(event)
    elsif event.state.control_mask? && event.state.mod1_mask?
      handle_ctrl_alt(event)
    elsif event.state.control_mask? && !event.state.mod1_mask?
      handle_ctrl(event)
    else
      handle_function_keys(event)
    end
  rescue => e
    warn "ERROR in KeyboardHandler#handle_key_press: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    false  # Allow event propagation on error
  end

  private

  # Handles Ctrl+Shift combinations
  def handle_ctrl_shift(event)
    case event.keyval
    when Gdk::Keyval::KEY_R
      # Ctrl+Shift+R: Reload browser code
      @callbacks[:window_actions][:reload_browser].call
      true
    when Gdk::Keyval::KEY_P
      # Ctrl+Shift+P: Video popout
      @callbacks[:window_actions][:open_video_popout].call
      true
    when Gdk::Keyval::KEY_B
      # Ctrl+Shift+B: Add PDF bookmarks (for markdown files)
      @callbacks[:markdown_actions][:add_pdf_bookmarks].call
      true
    when Gdk::Keyval::KEY_Q
      # Ctrl+Shift+Q: Add current tab to queue
      @callbacks[:queue_actions][:add_current].call
      true
    when Gdk::Keyval::KEY_Tab, Gdk::Keyval::KEY_ISO_Left_Tab
      # Ctrl+Shift+Tab: Previous tab (or previous queue item if queue sidebar is open)
      if @callbacks[:sidebar_actions][:visible].call &&
         @callbacks[:sidebar_actions][:mode].call == :queue
        @callbacks[:queue_actions][:previous_item].call
      else
        @callbacks[:tab_actions][:previous].call
      end
      true
    when Gdk::Keyval::KEY_Page_Down
      # Ctrl+Shift+PageDown: Move tab down (or move current page down in queue if queue sidebar is open)
      if @callbacks[:sidebar_actions][:visible].call &&
         @callbacks[:sidebar_actions][:mode].call == :queue
        @callbacks[:queue_actions][:move_current_down].call
      else
        @callbacks[:tab_actions][:move_down].call
      end
      true
    when Gdk::Keyval::KEY_Page_Up
      # Ctrl+Shift+PageUp: Move tab up (or move current page up in queue if queue sidebar is open)
      if @callbacks[:sidebar_actions][:visible].call &&
         @callbacks[:sidebar_actions][:mode].call == :queue
        @callbacks[:queue_actions][:move_current_up].call
      else
        @callbacks[:tab_actions][:move_up].call
      end
      true
    else
      false
    end
  end

  # Handles Ctrl combinations (without Shift or Alt)
  def handle_ctrl(event)
    case event.keyval
    when Gdk::Keyval::KEY_l
      # Ctrl+L: Focus and select URL bar
      # In zen mode, show toolbar temporarily
      if @callbacks[:toolbar_actions][:in_zen_mode].call
        @callbacks[:toolbar_actions][:show_toolbar].call
      end
      @callbacks[:toolbar_actions][:focus_url_entry].call
      true
    when Gdk::Keyval::KEY_b
      # Ctrl+B: Toggle sidebar (unless in zen mode)
      unless @callbacks[:toolbar_actions][:in_zen_mode].call
        @callbacks[:sidebar_actions][:toggle].call
      end
      true
    when Gdk::Keyval::KEY_d
      # Ctrl+D: Toggle dark mode
      @callbacks[:mode_actions][:toggle_dark_mode].call
      true
    when Gdk::Keyval::KEY_r
      # Ctrl+R: Refresh page
      current_tab = @callbacks[:tab_actions][:get_current].call
      current_tab.webview.reload if current_tab
      true
    when Gdk::Keyval::KEY_t
      # Ctrl+T: New tab
      @callbacks[:tab_actions][:create].call
      true
    when Gdk::Keyval::KEY_w
      # Ctrl+W: Close current tab
      @callbacks[:tab_actions][:close_current].call
      true
    when Gdk::Keyval::KEY_h
      # Ctrl+H: Show history in sidebar
      @callbacks[:sidebar_actions][:show_history].call
      true
    when Gdk::Keyval::KEY_q
      # Ctrl+Q: Show queue in sidebar
      @callbacks[:sidebar_actions][:show_queue].call
      true
    when Gdk::Keyval::KEY_e
      # Ctrl+E: Show tabs in sidebar
      @callbacks[:sidebar_actions][:show_tabs].call
      true
    when Gdk::Keyval::KEY_j
      # Ctrl+J: Show downloads in sidebar
      @callbacks[:sidebar_actions][:show_downloads].call
      true
    when Gdk::Keyval::KEY_f
      # Ctrl+F: Find in page
      @callbacks[:find_actions][:show_find_bar].call
      true
    when Gdk::Keyval::KEY_n
      # Ctrl+N: New window
      @callbacks[:window_actions][:open_new_window].call
      true
    when Gdk::Keyval::KEY_Tab
      # Ctrl+Tab: Next tab (or next queue item if queue sidebar is open)
      if @callbacks[:sidebar_actions][:visible].call &&
         @callbacks[:sidebar_actions][:mode].call == :queue
        @callbacks[:queue_actions][:next_item].call
      else
        @callbacks[:tab_actions][:next].call
      end
      true
    when Gdk::Keyval::KEY_bracketleft
      # Ctrl+[: Back
      @callbacks[:navigation_actions][:go_back].call
      true
    when Gdk::Keyval::KEY_bracketright
      # Ctrl+]: Forward
      @callbacks[:navigation_actions][:go_forward].call
      true
    when Gdk::Keyval::KEY_equal, Gdk::Keyval::KEY_plus
      # Ctrl+= or Ctrl++: Zoom in
      @callbacks[:zoom_actions][:zoom_in].call
      true
    when Gdk::Keyval::KEY_minus
      # Ctrl+-: Zoom out
      @callbacks[:zoom_actions][:zoom_out].call
      true
    when Gdk::Keyval::KEY_0
      # Ctrl+0: Reset zoom
      @callbacks[:zoom_actions][:reset].call
      true
    when Gdk::Keyval::KEY_comma
      # Ctrl+Comma: Open site permissions
      @callbacks[:window_actions][:open_site_permissions].call
      true
    when Gdk::Keyval::KEY_o
      # Ctrl+O: Open file
      @callbacks[:window_actions][:open_file].call
      true
    when Gdk::Keyval::KEY_u
      # Ctrl+U: Toggle markdown source view
      @callbacks[:markdown_actions][:toggle_source].call
      true
    when Gdk::Keyval::KEY_p
      # Ctrl+P: Print page
      @callbacks[:window_actions][:print_page].call
      true
    else
      false
    end
  end

  # Handles Ctrl+Alt combinations
  def handle_ctrl_alt(event)
    case event.keyval
    when Gdk::Keyval::KEY_q
      # Ctrl+Alt+Q: Remove current URL from queue and navigate to next
      @callbacks[:queue_actions][:remove_and_next].call
      true
    when Gdk::Keyval::KEY_t
      # Ctrl+Alt+T: Edit tags for current page (only if page is in queue)
      current_tab = @callbacks[:tab_actions][:get_current].call
      if current_tab
        current_url = current_tab.webview.uri
        # find_queue_entry_by_url callback returns entry hash or nil
        entry = @callbacks[:queue_actions][:find_queue_entry_by_url].call(current_url)

        if entry
          @callbacks[:queue_actions][:show_tag_edit_dialog].call(entry)
          return true
        end
      end

      false  # Not in queue - do nothing (silent no-op)
    else
      false
    end
  end

  # Handles function keys (no modifiers)
  def handle_function_keys(event)
    case event.keyval
    when Gdk::Keyval::KEY_F11
      # F11: Toggle zen mode
      @callbacks[:mode_actions][:toggle_zen_mode].call
      true
    when Gdk::Keyval::KEY_F12
      # F12: Toggle web inspector
      @callbacks[:mode_actions][:toggle_inspector].call
      true
    else
      false
    end
  end

  # Validates that all required callback groups and keys are present
  #
  # @param callbacks [Hash] The callbacks hash to validate
  # @raise [ArgumentError] if any required callback group or key is missing
  def validate_callbacks(callbacks)
    required_groups = {
      toolbar_actions: [:focus_url_entry, :show_toolbar, :in_zen_mode],
      sidebar_actions: [:toggle, :show_tabs, :show_history, :show_queue, :visible, :mode],
      tab_actions: [:create, :close_current, :next, :previous, :move_up, :move_down, :get_current],
      navigation_actions: [:go_back, :go_forward, :reload],
      queue_actions: [:add_current, :remove_and_next, :next_item, :previous_item, :move_current_up, :move_current_down, :find_queue_entry_by_url, :show_tag_edit_dialog],
      zoom_actions: [:zoom_in, :zoom_out, :reset],
      mode_actions: [:toggle_dark_mode, :toggle_zen_mode, :toggle_inspector],
      window_actions: [:reload_browser, :open_new_window, :open_video_popout, :print_page],
      find_actions: [:show_find_bar],
      markdown_actions: [:toggle_source, :add_pdf_bookmarks]
    }

    # Check for missing groups
    missing_groups = required_groups.keys - callbacks.keys
    unless missing_groups.empty?
      raise ArgumentError, "KeyboardHandler missing callback groups: #{missing_groups.join(', ')}"
    end

    # Check for missing keys within each group
    errors = []
    required_groups.each do |group_name, required_keys|
      group = callbacks[group_name]
      next unless group.is_a?(Hash)  # Skip validation if group isn't a hash (will fail elsewhere)

      missing_keys = required_keys - group.keys
      unless missing_keys.empty?
        errors << "#{group_name} missing keys: #{missing_keys.join(', ')}"
      end
    end

    unless errors.empty?
      raise ArgumentError, "KeyboardHandler validation errors:\n  #{errors.join("\n  ")}"
    end
  end
end
