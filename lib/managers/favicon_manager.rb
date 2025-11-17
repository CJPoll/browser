require 'tempfile'

# Manages favicon fetching with debouncing to select largest favicon variant
class FaviconManager
  # Creates a new favicon manager
  #
  # @param favicon_db [WebKit2Gtk::FaviconDatabase] WebKit favicon database
  # @param history_manager [HistoryManager] History manager for storing favicon data
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
          puts "DEBUG: Got favicon surface for #{page_uri}"
          # Convert to PNG to check size
          favicon_data = surface_to_png(surface)

          if favicon_data
            size = favicon_data.bytesize

            # Track largest favicon seen for this URL
            current_candidate = @favicon_candidates[page_uri]
            if !current_candidate || size > current_candidate[:size]
              puts "DEBUG: New largest favicon candidate: #{size} bytes (previous: #{current_candidate ? current_candidate[:size] : 0} bytes)"
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
                puts "DEBUG: Debounce timer fired - saving favicon (#{candidate[:size]} bytes) for #{page_uri}"
                save_favicon_data(page_uri, candidate[:surface])
                @favicon_candidates.delete(page_uri)
                @favicon_timers.delete(page_uri)
              end
              false  # Don't repeat
            end
          end
        else
          puts "DEBUG: No favicon for #{page_uri}, trying root domain..."
          # Try to get favicon from root domain as fallback
          try_root_domain_favicon(page_uri)
        end
      rescue => e
        if e.message.include?("Unknown favicon")
          puts "DEBUG: No favicon for #{page_uri}, trying root domain..."
          try_root_domain_favicon(page_uri)
        else
          puts "DEBUG: Error getting favicon for #{page_uri}: #{e.message}"
        end
      end
    end
  end

  private

  # Sets up favicon-changed signal handler
  def setup_favicon_signal
    @favicon_db.signal_connect("favicon-changed") do |_db, page_uri, favicon_uri|
      puts "DEBUG: Favicon changed for page: #{page_uri}"
      puts "DEBUG: Favicon URI: #{favicon_uri}"

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

      puts "DEBUG: Trying favicon from #{root_uri}"

      @favicon_db.get_favicon(root_uri, nil) do |_object, result|
        begin
          surface = @favicon_db.get_favicon_finish(result)

          if surface
            puts "DEBUG: Got root domain favicon for #{page_uri}"
            save_favicon_data(page_uri, surface)
          else
            puts "DEBUG: No root domain favicon available for #{page_uri}"
          end
        rescue => e
          puts "DEBUG: Error getting root domain favicon: #{e.message}"
        end
      end
    rescue URI::InvalidURIError => e
      puts "DEBUG: Invalid URI for root domain lookup: #{e.message}"
    end
  end

  # Saves favicon data to history database and updates tabs
  #
  # @param page_uri [String] Page URI
  # @param surface [Cairo::Surface] Cairo surface containing favicon
  # @return [void]
  def save_favicon_data(page_uri, surface)
    favicon_data = surface_to_png(surface)

    if favicon_data
      puts "DEBUG: Saving favicon data (#{favicon_data.bytesize} bytes) for #{page_uri}"
      @history_manager.update_favicon(page_uri, favicon_data)

      # Update tabs with favicon data (access tabs via callback)
      # Gap 28 RESOLUTION: Tabs accessor timing is INTENTIONAL
      # Tabs are accessed dynamically when timer fires (300ms after last favicon event)
      # This matches current behavior - tabs accessed at save time, not at favicon event time
      # If tabs have changed in the meantime (closed, navigated), that's okay - loop skips them
      tabs = @tabs_accessor.call
      tabs.each do |tab|
        if tab.uri == page_uri
          tab.favicon_data = favicon_data
        end
      end

      # Refresh tabs to show the new favicon
      # Gap 25 RESOLUTION: Current implementation calls refresh_tabs DIRECTLY (line 978)
      # NOT via callback. Callback pattern would be enhancement, not extraction.
      # DECISION: Match current implementation - call refresh_tabs via callback parameter
      @on_favicon_updated.call if @on_favicon_updated
    else
      puts "DEBUG: Failed to convert favicon to PNG for #{page_uri}"
    end
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
