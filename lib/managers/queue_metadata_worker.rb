require 'net/http'
require 'uri'
require 'cgi'

# Background worker for fetching metadata (title and favicon) for queue entries
class QueueMetadataWorker
  # Creates a new background worker
  #
  # @param queue_manager [QueueManager] Queue manager instance for database updates
  def initialize(queue_manager)
    @queue_manager = queue_manager
    @work_queue = Thread::Queue.new
    @running = true
    @worker_thread = Thread.new { worker_loop }

    # Callback invoked on main thread after metadata is fetched
    # Signature: -> { ... }
    @on_metadata_fetched = nil
  end

  # Sets callback to invoke after metadata is fetched
  # Callback is invoked on main thread via GLib::Idle.add
  #
  # @param callback [Proc] Callback proc (no arguments)
  # @return [void]
  def on_metadata_fetched=(callback)
    @on_metadata_fetched = callback
  end

  # Enqueues a queue entry for metadata fetching
  #
  # @param entry_id [Integer] Queue entry ID
  # @param url [String] URL to fetch metadata for
  # @return [void]
  def enqueue(entry_id, url)
    @work_queue.push({id: entry_id, url: url})
  end

  # Stops the background worker gracefully
  # Waits up to 1 second for worker thread to finish
  #
  # @return [void]
  def stop
    @running = false
    @work_queue.push(nil)  # Poison pill to unblock worker
    @worker_thread.join(1) if @worker_thread&.alive?
  end

  private

  # Main worker loop - processes work items from queue
  def worker_loop
    while @running
      item = @work_queue.pop
      break if item.nil?  # Poison pill

      begin
        fetch_metadata(item[:id], item[:url])
      rescue => e
        warn "Error fetching metadata for #{item[:url]}: #{e.message}"
      end
    end
  end

  # Fetches title and favicon for a queue entry
  #
  # @param entry_id [Integer] Queue entry ID (for logging only)
  # @param url [String] URL to fetch
  # @return [void]
  def fetch_metadata(entry_id, url)
    uri = URI.parse(url)

    # Fetch the page HTML
    # NOTE: Current implementation does NOT rescue timeout exceptions
    # HTTP client throws Net::OpenTimeout/Net::ReadTimeout but they are not caught
    # They propagate to outer rescue in worker_loop
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                               open_timeout: 5, read_timeout: 5) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
      http.request(request)
    end

    return unless response.is_a?(Net::HTTPSuccess)

    html = response.body
    title = extract_title_from_html(html)
    favicon_url = extract_favicon_url_from_html(html, uri)

    # Fetch favicon if found
    favicon_data = nil
    if favicon_url
      favicon_data = fetch_favicon(favicon_url)
    else
      # Try default /favicon.ico
      default_favicon_url = "#{uri.scheme}://#{uri.host}/favicon.ico"
      favicon_data = fetch_favicon(default_favicon_url)
    end

    # Update database (safe from background thread)
    @queue_manager.update_title(url, title) if title
    @queue_manager.update_favicon(url, favicon_data) if favicon_data

    # Notify callback on main thread
    # Gap 27 RESOLUTION: Callback context clarification
    # The callback is invoked INSIDE the GLib::Idle.add block (already on main thread)
    # This means the callback itself executes on the main thread and can safely call GTK methods
    # Current implementation checks @sidebar_mode inside the GLib::Idle.add block
    # The spec callback is invoked unconditionally here
    # The sidebar mode check happens in simple_browser.rb when assigning the callback
    if @on_metadata_fetched
      GLib::Idle.add do
        # Callback executes HERE (on main thread) - safe to call GTK methods
        @on_metadata_fetched.call
        false  # Don't repeat
      end
    end
  end

  # Extracts page title from HTML
  #
  # @param html [String] HTML content
  # @return [String, nil] Page title or nil if not found
  def extract_title_from_html(html)
    # Simple regex to extract title
    match = html.match(/<title[^>]*>(.*?)<\/title>/im)
    return nil unless match

    title = match[1].strip

    # Ensure UTF-8 encoding, replacing invalid characters
    title = title.force_encoding('UTF-8')
    unless title.valid_encoding?
      # Try different encodings
      title = title.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    CGI.unescapeHTML(title)
  end

  # Extracts favicon URL from HTML
  #
  # @param html [String] HTML content
  # @param base_uri [URI] Base URI for resolving relative URLs
  # @return [String, nil] Absolute favicon URL or nil if not found
  def extract_favicon_url_from_html(html, base_uri)
    # Look for <link rel="icon"> or <link rel="shortcut icon">
    match = html.match(/<link[^>]*rel=["'](?:shortcut )?icon["'][^>]*href=["']([^"']+)["']/im)
    return nil unless match

    favicon_path = match[1]

    # Make absolute URL if relative
    if favicon_path.start_with?('http')
      favicon_path
    elsif favicon_path.start_with?('//')
      "#{base_uri.scheme}:#{favicon_path}"
    elsif favicon_path.start_with?('/')
      "#{base_uri.scheme}://#{base_uri.host}#{favicon_path}"
    else
      "#{base_uri.scheme}://#{base_uri.host}/#{favicon_path}"
    end
  end

  # Fetches favicon data from URL
  #
  # @param favicon_url [String] URL to fetch favicon from
  # @return [String, nil] Binary favicon data or nil on error
  def fetch_favicon(favicon_url)
    uri = URI.parse(favicon_url)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                               open_timeout: 3, read_timeout: 3) do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request)
    end

    return response.body if response.is_a?(Net::HTTPSuccess)
    nil
  rescue => e
    # Silently fail for favicons
    nil
  end
end
