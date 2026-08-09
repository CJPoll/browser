require 'uri'
require_relative '../domain/external_schemes'
require_relative '../domain/url_classifier'
require_relative '../managers/external_opener'

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
  # @param external_opener [Managers::ExternalOpener] Opens URIs that belong
  #   to another application
  # @raise [ArgumentError] if required callbacks are missing
  def initialize(callbacks, external_opener: Managers::ExternalOpener.new)
    validate_callbacks(callbacks)
    @callbacks = callbacks
    @external_opener = external_opener
  end

  # Navigates to the given URL or search query
  #
  # @param text [String] The text from the URL entry
  # @return [void]
  def navigate_to(text)
    return unless @callbacks[:get_current_tab].call

    text_stripped = text.strip

    # Check for external URL schemes that should be handled by the system
    if Domain::ExternalSchemes.external?(text_stripped)
      @external_opener.open_uri(text_stripped)
      return
    end

    url = build_url(text_stripped)

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
    warn "ERROR in NavigationHandler#navigate_to: #{e.message}"
    warn e.backtrace.first(5).join("\n")
  end

  private

  # Turns URL-bar text into the URL to load
  #
  # Home-relative paths are expanded here rather than in Domain: expansion
  # reads the environment, which Domain may not do.
  #
  # @param text [String] Stripped text from the URL entry
  # @return [String] The URL to load
  def build_url(text)
    case Domain::UrlClassifier.classify(text)
    when :absolute_url then text
    when :absolute_path then "file://#{text}"
    when :home_path then "file://#{File.expand_path(text)}"
    when :domain then "https://#{text}"
    else Domain::UrlClassifier.search_url(text)
    end
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
