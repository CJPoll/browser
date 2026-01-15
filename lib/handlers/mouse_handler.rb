require 'gtk3'

# Handles mouse button events (back/forward navigation, Ctrl+Click)
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
# All callbacks are expected to run synchronously on the main thread.
class MouseHandler
  # URL schemes that should be delegated to xdg-open instead of loaded in WebKit
  # These are application-specific protocols handled by external programs
  EXTERNAL_SCHEMES = %w[
    warp spotify discord slack steam zoommtg zoomus
    tg telegram signal viber whatsapp
    vscode vscodium cursor
    obsidian notion
    mailto tel sms
  ].freeze

  # Creates a new mouse handler
  #
  # @param callbacks [Hash] Hash of callback procs:
  #   - :get_current_tab => -> { Tab or nil }
  #   - :create_new_tab => ->(uri, switch_to:) { creates tab }
  #   - :handle_markdown_navigation => ->(webview, uri) { true if handled } (optional)
  # @raise [ArgumentError] if required callbacks are missing
  def initialize(callbacks)
    validate_callbacks(callbacks)
    @callbacks = callbacks
  end

  # Handles button-press-event for back/forward mouse buttons
  # Can be attached to window or webview
  #
  # @param widget [Gtk::Widget] The widget that received the event
  # @param event [Gdk::EventButton] The button press event
  # @return [Boolean] true if event handled, false otherwise
  def handle_button_press(widget, event)
    current_tab = @callbacks[:get_current_tab].call
    return false unless current_tab

    case event.button
    when 4, 6, 8
      # Mouse back button (trying 4, 6, and 8)
      if current_tab.webview.can_go_back?
        current_tab.webview.go_back
        true  # Event handled
      else
        false
      end
    when 5, 7, 9
      # Mouse forward button (trying 5, 7, and 9)
      if current_tab.webview.can_go_forward?
        current_tab.webview.go_forward
        true  # Event handled
      else
        false
      end
    else
      false  # Event not handled
    end
  rescue => e
    puts "ERROR in MouseHandler#handle_button_press: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    false  # Allow event propagation on error
  end

  # Handles decide-policy signal for Ctrl+Click to open in new tab
  # and external URL schemes (warp://, spotify://, etc.)
  # Should be attached to webview decide-policy signal
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @param decision [WebKit2Gtk::PolicyDecision] The policy decision
  # @param decision_type [Symbol] The type of policy decision
  # @param current_tab [Tab] The tab this webview belongs to
  # @return [Boolean] true if event handled, false to let default handlers run
  def handle_decide_policy(webview, decision, decision_type, current_tab)
    # Only handle navigation actions
    return false unless decision_type == :navigation_action

    # Only handle if this is the current tab
    return false unless @callbacks[:get_current_tab].call == current_tab

    navigation_action = decision.navigation_action
    uri_request = navigation_action.request
    uri = uri_request.uri

    # Check for external URL schemes that should be handled by the system
    if uri && external_scheme?(uri)
      decision.ignore
      system("xdg-open", uri)
      return true
    end

    # Check for markdown files that should be rendered
    if uri && @callbacks[:handle_markdown_navigation]
      if @callbacks[:handle_markdown_navigation].call(webview, uri)
        decision.ignore
        return true
      end
    end

    modifiers = navigation_action.modifiers

    # Check if Ctrl key is pressed
    # Convert modifiers to integer and check for CONTROL_MASK
    ctrl_pressed = (modifiers.to_i & Gdk::ModifierType::CONTROL_MASK.to_i) != 0

    if ctrl_pressed
      # Only handle http/https links
      if uri && (uri.start_with?("http://") || uri.start_with?("https://"))
        # Ignore this navigation in the current tab
        decision.ignore

        # Open in new tab (but don't switch to it)
        @callbacks[:create_new_tab].call(uri, switch_to: false)

        true  # Stop signal propagation
      else
        false  # Let other handlers process
      end
    else
      false  # Let the navigation proceed normally
    end
  rescue => e
    puts "ERROR in MouseHandler#handle_decide_policy: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    false  # Allow default handlers to run on error
  end

  private

  # Checks if a URL uses an external scheme that should be handled by the system
  #
  # @param url [String] The URL to check
  # @return [Boolean] true if the URL uses an external scheme
  def external_scheme?(url)
    return false unless url.include?("://")

    scheme = url.split("://").first.downcase
    EXTERNAL_SCHEMES.include?(scheme)
  end

  # Validates that all required callbacks are present
  #
  # @param callbacks [Hash] The callbacks hash to validate
  # @raise [ArgumentError] if any required callback is missing
  def validate_callbacks(callbacks)
    required = [:get_current_tab, :create_new_tab]
    missing = required - callbacks.keys
    raise ArgumentError, "MouseHandler missing required callbacks: #{missing.join(', ')}" unless missing.empty?
  end
end
