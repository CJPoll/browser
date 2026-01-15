require 'webkit2-gtk'

# Individual browser tab containing a WebView
class Tab
  attr_reader :webview, :list_box_row
  attr_accessor :title, :uri, :favicon_data

  # Creates a new browser tab
  #
  # @param web_context [WebKit2Gtk::WebContext] Shared web context for cookies/cache
  # @param favicon_db [WebKit2Gtk::FaviconDatabase] Favicon database (unused, kept for compatibility)
  # @param initial_uri [String] Initial URI to load
  def initialize(web_context, favicon_db, initial_uri = "https://www.google.com")
    @webview = WebKit2Gtk::WebView.new(context: web_context)
    @title = "New Tab"
    @uri = initial_uri
    @favicon_data = nil
    @favicon_db = favicon_db
    @list_box_row = nil  # Will be set when added to sidebar

    # Enable developer tools and experimental features
    settings = @webview.settings
    settings.enable_developer_extras = true
    settings.enable_back_forward_navigation_gestures = true
    settings.enable_media_stream = true
    settings.enable_webrtc = true

    # Set Chrome user agent for sites that block WebKitGTK (e.g., Discord)
    apply_user_agent_for_uri(initial_uri)

    # Enable experimental features for modern web compatibility
    begin
      experimental_features = WebKit2Gtk::Settings.experimental_features

      # OPFS support (needed for 1Password and similar apps)
      opfs_features = ['StorageAPI', 'FileSystemAccess', 'FileSystemWritableStream', 'AccessHandle']

      # Standard features enabled by default in Safari
      safari_standard = ['PopoverAttribute', 'WebShareFileAPI', 'ViewTransitions',
                         'CSSUnprefixedBackdropFilter', 'ServiceWorkers', 'CSSContentVisibility']

      # Cross-browser standard features
      cross_browser_standard = ['BroadcastChannel', 'CompressionStream', 'CSSOMViewSmoothScrolling',
                                'LazyImageLoading', 'Notifications', 'PermissionsAPI',
                                'WebLocksAPI', 'URLPatternAPI']

      features_to_enable = opfs_features + safari_standard + cross_browser_standard

      features_to_enable.each do |feature_id|
        # Find the feature by iterating through the FeatureList
        feature = nil
        (0...experimental_features.length).each do |i|
          f = experimental_features.get(i)
          if f.identifier == feature_id
            feature = f
            break
          end
        end

        if feature
          settings.set_feature_enabled(feature, true)
        end
      end
    rescue => e
      warn "Could not enable experimental features: #{e.message}"
    end

    # Connect signals
    setup_signals

    # NOTE: Initial URI is NOT loaded here. BrowserWindow.create_new_tab
    # loads it after connecting decide-policy signal handler, which allows
    # markdown files and other special URLs to be intercepted.
  end

  # Loads a URI into this tab's webview
  #
  # @param uri [String] The URI to load
  def load_uri(uri)
    @webview.load_uri(uri)
  end

  # Sets up WebView signal handlers
  def setup_signals
    @webview.signal_connect("notify::uri") do
      @uri = @webview.uri
      apply_user_agent_for_uri(@uri)
      update_list_box_row if @list_box_row
    end

    @webview.signal_connect("notify::title") do
      @title = @webview.title || "Untitled"
      update_list_box_row if @list_box_row
    end

  end

  # Updates the sidebar list box row for this tab
  # NOTE: This method remains empty as in current implementation
  # Actual UI updates happen via BrowserWindow's signal handlers
  def update_list_box_row
    # This will be called to refresh the tab's appearance in the sidebar
    # The actual implementation will be in BrowserWindow
  end

  private

  # Chrome 120 on Linux user agent (Discord requires Chrome, Firefox, Edge, or Opera)
  CHROME_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  # Hosts that need Chrome user agent to work properly
  CHROME_UA_HOSTS = %w[
    discord.com
    discordapp.com
  ].freeze

  # Applies appropriate user agent based on the URI
  #
  # @param uri [String, nil] The URI to check
  def apply_user_agent_for_uri(uri)
    return unless uri

    begin
      host = URI.parse(uri).host&.downcase
      return unless host

      settings = @webview.settings
      if CHROME_UA_HOSTS.any? { |h| host == h || host.end_with?(".#{h}") }
        settings.user_agent = CHROME_USER_AGENT
      else
        # Reset to default (nil clears custom user agent)
        settings.user_agent = nil
      end
    rescue URI::InvalidURIError
      # Invalid URI, ignore
    end
  end
end
