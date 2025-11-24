require 'gtk3'
require 'webkit2-gtk'

# Window for displaying popup content (OAuth dialogs, etc.)
class PopupWindow < Gtk::Window
  attr_reader :webview

  # Creates a new popup window
  #
  # @param related_view [WebKit2Gtk::WebView] WebView to relate to (for window features)
  # @param parent_window [Gtk::Window] Parent window for transient relationship
  def initialize(related_view, parent_window = nil)
    super(:toplevel)

    set_default_size(600, 700)
    set_title("Popup")
    set_transient_for(parent_window) if parent_window

    # Create WebView related to the original (shares web process, gets window features)
    @webview = WebKit2Gtk::WebView.new(related_view: related_view)

    # Enable basic settings
    settings = @webview.settings
    settings.enable_developer_extras = true

    # Add WebView to window
    add(@webview)

    # Show window when WebKit signals it's ready (has configured window features)
    @webview.signal_connect("ready-to-show") do
      show_all
      present
    end

    # Update title when page loads
    @webview.signal_connect("notify::title") do
      title = @webview.title
      set_title(title) if title && !title.empty?
    end

    # Handle close request from JavaScript (window.close())
    @webview.signal_connect("close") do
      destroy
    end

    # Handle nested popups (create signal)
    @webview.signal_connect("create") do |wv, navigation_action|
      # For nested popups, create another popup window related to this one
      nested_popup = PopupWindow.new(@webview, self)
      nested_popup.webview
    end
  end
end
