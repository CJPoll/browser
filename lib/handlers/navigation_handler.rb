require 'cgi'

# Handles URL navigation logic (parsing, search detection)
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
# All callbacks are expected to run synchronously on the main thread.
class NavigationHandler
  # Creates a new navigation handler
  #
  # @param callbacks [Hash] Hash of callback procs:
  #   - :get_current_tab => -> { Tab or nil }
  #   - :in_zen_mode => -> { true/false }
  #   - :get_toolbar => -> { Gtk::Box toolbar widget }
  # @raise [ArgumentError] if required callbacks are missing
  def initialize(callbacks)
    validate_callbacks(callbacks)
    @callbacks = callbacks
  end

  # URL schemes that should be delegated to xdg-open instead of loaded in WebKit
  # These are application-specific protocols handled by external programs
  EXTERNAL_SCHEMES = %w[
    warp spotify discord slack steam zoommtg zoomus
    tg telegram signal viber whatsapp
    vscode vscodium cursor
    obsidian notion
    mailto tel sms
  ].freeze

  # Navigates to the given URL or search query
  #
  # @param text [String] The text from the URL entry
  # @return [void]
  def navigate_to(text)
    return unless @callbacks[:get_current_tab].call

    text_stripped = text.strip

    # Check for external URL schemes that should be handled by the system
    if external_scheme?(text_stripped)
      system("xdg-open", text_stripped)
      return
    end

    # Check if it looks like a URL (has a TLD and no spaces)
    # or if it already starts with a protocol
    if text_stripped.start_with?("http://", "https://", "file://")
      url = text_stripped
    elsif text_stripped.start_with?("/")
      # Absolute file path - convert to file:// URL
      url = "file://#{text_stripped}"
    elsif text_stripped.start_with?("~/")
      # Home-relative path - expand and convert to file:// URL
      expanded = File.expand_path(text_stripped)
      url = "file://#{expanded}"
    elsif text_stripped.match?(/^[\w-]+\.[\w.-]+/) && !text_stripped.include?(' ')
      # Looks like a domain (e.g., "example.com" or "github.com")
      url = "https://#{text_stripped}"
    else
      # Treat as a search query
      query = CGI.escape(text_stripped)
      url = "https://www.google.com/search?q=#{query}"
    end

    # Normalize URL (e.g., rewrite youtube.com to www.youtube.com)
    url = normalize_url(url)

    current_tab = @callbacks[:get_current_tab].call
    current_tab.webview.load_uri(url)

    # In zen mode, hide toolbar after submitting URL
    if @callbacks[:in_zen_mode].call
      toolbar = @callbacks[:get_toolbar].call
      toolbar.hide
    end
  rescue => e
    puts "ERROR in NavigationHandler#navigate_to: #{e.message}"
    puts e.backtrace.first(5).join("\n")
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

  # Normalizes URLs for sites that require specific subdomains
  #
  # @param url [String] The URL to normalize
  # @return [String] The normalized URL
  def normalize_url(url)
    return url unless url

    begin
      uri = URI.parse(url)

      # YouTube requires www subdomain for proper auth cookie handling
      if uri.host == 'youtube.com'
        uri.host = 'www.youtube.com'
        return uri.to_s
      end

      url
    rescue URI::InvalidURIError
      # If URL parsing fails, return original
      url
    end
  end

  # Validates that all required callbacks are present
  #
  # @param callbacks [Hash] The callbacks hash to validate
  # @raise [ArgumentError] if any required callback is missing
  def validate_callbacks(callbacks)
    required = [:get_current_tab, :in_zen_mode, :get_toolbar]
    missing = required - callbacks.keys
    raise ArgumentError, "NavigationHandler missing required callbacks: #{missing.join(', ')}" unless missing.empty?
  end
end
