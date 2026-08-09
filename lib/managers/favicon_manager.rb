require 'tempfile'

# Manages favicon fetching with debouncing to select largest favicon variant
class FaviconManager
  # Creates a new favicon manager
  #
  # @param favicon_db [WebKit2Gtk::FaviconDatabase] WebKit favicon database
  # @param history_manager [Managers::HistoryManager] History use cases, for storing favicon data
  # @param tabs_accessor [Proc] Proc that returns the current tabs array (e.g., -> { @tabs })
  def initialize(favicon_db, history_manager, tabs_accessor)
    @favicon_db = favicon_db
    @history_manager = history_manager
    @tabs_accessor = tabs_accessor

    # Debouncing state
    @favicon_timers = {}      # url => GLib timeout source ID
    @favicon_candidates = {}  # url => {size, surface} (NO tabs field)

    # Callback invoked when favicon data is saved to database
    # Callback executes synchronously on main thread (already inside GLib::Idle.add context)
    # Used to trigger UI refresh (e.g., tabs sidebar refresh)
    # Signature: -> { ... }
    @on_favicon_updated = nil

    # Connect to favicon-changed signal
    setup_favicon_signal if @favicon_db
  end

  # Sets callback to invoke when favicon data is saved
  #
  # @param callback [Proc] Callback proc (no arguments)
  # @return [void]
  def on_favicon_updated=(callback)
    @on_favicon_updated = callback
  end

  # Fetches and saves favicon for a page URI
  # Uses debouncing to select largest favicon variant
  #
  # @param page_uri [String] Page URI to fetch favicon for
  # @return [void]
  def fetch_and_save_favicon(page_uri)
    return unless @favicon_db

    # Get the favicon asynchronously from the database
    @favicon_db.get_favicon(page_uri, nil) do |_object, result|
      begin
        surface = @favicon_db.get_favicon_finish(result)

        if surface
          # Convert to PNG to check size
          favicon_data = surface_to_png(surface)

          if favicon_data
            size = favicon_data.bytesize

            # Track largest favicon seen for this URL
            current_candidate = @favicon_candidates[page_uri]
            if !current_candidate || size > current_candidate[:size]
              @favicon_candidates[page_uri] = {size: size, surface: surface}
            end

            # Cancel previous timer if exists
            if @favicon_timers[page_uri]
              GLib::Source.remove(@favicon_timers[page_uri])
            end

            # Set debounce timer - save after 300ms of silence
            @favicon_timers[page_uri] = GLib::Timeout.add(300) do
              # Save the largest favicon we saw
              candidate = @favicon_candidates[page_uri]
              if candidate
                save_favicon_data(page_uri, candidate[:surface])
                @favicon_candidates.delete(page_uri)
                @favicon_timers.delete(page_uri)
              end
              false  # Don't repeat
            end
          end
        else
          # Try to get favicon from root domain as fallback
          try_root_domain_favicon(page_uri)
        end
      rescue => e
        if e.message.include?("Unknown favicon")
          try_root_domain_favicon(page_uri)
        else
          warn "Error getting favicon for #{page_uri}: #{e.message}"
        end
      end
    end
  end

  private

  # Sets up favicon-changed signal handler
  def setup_favicon_signal
    @favicon_db.signal_connect("favicon-changed") do |_db, page_uri, favicon_uri|
      # Favicon changed - try to save it for the current page
      fetch_and_save_favicon(page_uri)
    end
  end

  # Tries to fetch favicon from root domain as fallback
  #
  # @param page_uri [String] Page URI
  # @return [void]
  def try_root_domain_favicon(page_uri)
    return unless @favicon_db

    begin
      uri = URI.parse(page_uri)
      root_uri = "#{uri.scheme}://#{uri.host}/"

      return if root_uri == page_uri  # Already tried root domain

      @favicon_db.get_favicon(root_uri, nil) do |_object, result|
        begin
          surface = @favicon_db.get_favicon_finish(result)

          save_favicon_data(page_uri, surface) if surface
        rescue => e
          warn "Error getting root domain favicon: #{e.message}"
        end
      end
    rescue URI::InvalidURIError => e
      warn "Invalid URI for root domain lookup: #{e.message}"
    end
  end

  # Saves favicon data to history database and updates tabs
  #
  # @param page_uri [String] Page URI
  # @param surface [Cairo::Surface] Cairo surface containing favicon
  # @return [void]
  def save_favicon_data(page_uri, surface)
    # A conversion failure has already reported its reason from `surface_to_png`.
    favicon_data = surface_to_png(surface)
    return unless favicon_data

    @history_manager.update_favicon(page_uri, favicon_data)

    # Update tabs with favicon data (access tabs via callback).
    # Tabs are read when the debounce timer fires, not when the favicon event
    # arrived; a tab that has since closed or navigated is simply skipped.
    @tabs_accessor.call.each do |tab|
      tab.favicon_data = favicon_data if tab.uri == page_uri
    end

    # Refresh tabs to show the new favicon
    @on_favicon_updated&.call
  end

  # Converts Cairo surface to PNG binary data
  #
  # @param surface [Cairo::Surface] Cairo surface to convert
  # @return [String, nil] PNG binary data or nil on error
  def surface_to_png(surface)
    return nil unless surface

    # Create a temporary file to write the PNG
    temp = Tempfile.new(['favicon', '.png'])
    temp.close

    begin
      # Write surface to PNG file
      surface.write_to_png(temp.path)

      # Read the PNG data
      png_data = File.binread(temp.path)
      png_data
    rescue => e
      warn "Failed to convert favicon: #{e.message}"
      nil
    ensure
      temp.unlink
    end
  end
end
