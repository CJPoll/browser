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

  # Navigates to the given URL or search query
  #
  # @param text [String] The text from the URL entry
  # @return [void]
  def navigate_to(text)
    return unless @callbacks[:get_current_tab].call

    text_stripped = text.strip

    # Check if it looks like a URL (has a TLD and no spaces)
    # or if it already starts with a protocol
    if text_stripped.start_with?("http://", "https://")
      url = text_stripped
    elsif text_stripped.match?(/^[\w-]+\.[\w.-]+/) && !text_stripped.include?(' ')
      # Looks like a domain (e.g., "example.com" or "github.com")
      url = "https://#{text_stripped}"
    else
      # Treat as a search query
      query = CGI.escape(text_stripped)
      url = "https://www.google.com/search?q=#{query}"
    end

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
