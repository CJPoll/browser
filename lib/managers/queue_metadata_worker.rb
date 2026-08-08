require 'uri'
require_relative '../adapters/auto_tag_rules_store'
require_relative '../adapters/http_fetcher'
require_relative '../domain/auto_tagger'
require_relative '../domain/page_metadata'

module Managers
  # Fills in the metadata a queue entry is missing.
  #
  # An entry added from a link context menu knows only its URL. This worker
  # fetches the page in the background, reads its title, favicon and -- for
  # YouTube videos -- channel and publish date out of it, stores them, and
  # applies the auto-tagging rules.
  #
  # It owns the background thread and the order of the steps; the fetching is
  # `Adapters::HttpFetcher`'s and the parsing is `Domain::PageMetadata`'s.
  class QueueMetadataWorker
    # Runs a block on the GTK main thread. Injected so a test can run the
    # callback itself: nothing pumps the main loop in a test process.
    MAIN_THREAD_SCHEDULER = lambda do |&block|
      GLib::Idle.add do
        block.call
        false # Don't repeat
      end
    end

    # Creates a new background worker
    #
    # @param queue_manager [Managers::QueueManager] Queue manager for persistence
    # @param http [Adapters::HttpFetcher] Fetches pages, APIs and favicons
    # @param auto_tagger [Domain::AutoTagger, nil] Rules to apply; defaults to
    #   the rules the browser ships with
    # @param scheduler [#call] Runs a block on the main thread
    def initialize(queue_manager,
                   http: Adapters::HttpFetcher.new,
                   auto_tagger: nil,
                   scheduler: MAIN_THREAD_SCHEDULER)
      @queue_manager = queue_manager
      @http = http
      @auto_tagger = auto_tagger || Domain::AutoTagger.from_rules(Adapters::AutoTagRulesStore.new.load)
      @scheduler = scheduler

      @work_queue = Thread::Queue.new
      @running = true
      @worker_thread = Thread.new { worker_loop }

      # Callback invoked on main thread after metadata is fetched
      # Signature: -> { ... }
      @on_metadata_fetched = nil
    end

    # Sets callback to invoke after metadata is fetched
    # Callback is invoked on the main thread
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
      @work_queue.push({ id: entry_id, url: url })
    end

    # Fetches and stores the metadata for one entry, on the calling thread
    #
    # This is the unit of work `enqueue` schedules; it is public because it is
    # the worker's actual behaviour, and the thread is only how it gets run.
    #
    # @param entry_id [Integer] Queue entry ID
    # @param url [String] URL to fetch
    # @return [void]
    def process(entry_id, url)
      metadata = build_metadata(url)
      return unless metadata

      persist_metadata(entry_id, url, metadata)
      notify_metadata_fetched
    end

    # Stops the background worker gracefully
    # Waits up to 1 second for worker thread to finish
    #
    # @return [void]
    def stop
      @running = false
      @work_queue.push(nil) # Poison pill to unblock worker
      @worker_thread.join(1) if @worker_thread&.alive?
    end

    private

    # Main worker loop - processes work items from queue
    def worker_loop
      while @running
        item = @work_queue.pop
        break if item.nil? # Poison pill

        begin
          process(item[:id], item[:url])
        rescue => e
          warn "Error fetching metadata for #{item[:url]}: #{e.message}"
        end
      end
    end

    # Fetches the page and reads everything worth storing out of it
    #
    # @param url [String] URL to fetch
    # @return [Hash, nil] Metadata, or nil if the page could not be fetched
    def build_metadata(url)
      uri = URI.parse(url)

      html = @http.fetch_page(url)
      return nil unless html

      is_youtube = Domain::PageMetadata.youtube_video?(url)
      video = is_youtube ? youtube_metadata(url, html) : {}

      {
        title: video[:title] || Domain::PageMetadata.title_from_html(html),
        channel: video[:channel],
        publish_date: video[:date],
        favicon_data: fetch_favicon(Domain::PageMetadata.favicon_url(html, uri)),
        is_youtube: is_youtube
      }
    end

    # Video metadata, from the page's structured data and the oEmbed API
    #
    # The page's JSON-LD carries the title and publish date; only oEmbed names
    # the channel, so it is consulted whenever the channel is still unknown --
    # which is also what covers a page with no usable JSON-LD at all.
    #
    # @param url [String] Video URL
    # @param html [String] Page HTML
    # @return [Hash] `{title:, channel:, date:}`, any of which may be nil
    def youtube_metadata(url, html)
      from_page = Domain::PageMetadata.youtube_metadata_from_jsonld(html) || {}
      return from_page if from_page[:channel]

      from_oembed = fetch_oembed_metadata(url) || {}

      {
        title: from_page[:title] || from_oembed[:title],
        channel: from_oembed[:channel],
        date: from_page[:date]
      }
    end

    # @param url [String] Video URL
    # @return [Hash, nil] oEmbed metadata, or nil if it could not be read
    def fetch_oembed_metadata(url)
      body = @http.fetch_api(Domain::PageMetadata.oembed_url(url))
      return nil unless body

      Domain::PageMetadata.youtube_metadata_from_oembed(body)
    rescue => e
      # Network error, JSON parse error, etc. The entry is still worth saving.
      warn "oEmbed API error for #{url}: #{e.message}"
      nil
    end

    # @param favicon_url [String] URL to fetch the favicon from
    # @return [String, nil] Binary favicon data, or nil if unavailable
    def fetch_favicon(favicon_url)
      @http.fetch_asset(favicon_url)
    rescue
      # Silently fail for favicons -- most sites that lack one fail this way,
      # and an entry without an icon is still a good entry.
      nil
    end

    # Stores the metadata and applies the tagging rules
    #
    # @param entry_id [Integer] Queue entry ID
    # @param url [String] URL of the entry
    # @param metadata [Hash] Metadata hash from build_metadata
    # @return [void]
    def persist_metadata(entry_id, url, metadata)
      @queue_manager.update_title(url, metadata[:title]) if metadata[:title]
      @queue_manager.update_favicon(url, metadata[:favicon_data]) if metadata[:favicon_data]
      @queue_manager.update_published_at(url, Time.at(metadata[:publish_date])) if metadata[:publish_date]

      # Auto-assign tags for YouTube videos
      if metadata[:is_youtube]
        # WART (preserved): an entry that has been removed since it was
        # enqueued stops the tagging here, so the rule-based tags below are
        # skipped too.
        return unless @queue_manager.find_by_id(entry_id)

        @queue_manager.assign_tag_by_name(entry_id, 'YouTube')

        channel = metadata[:channel]
        @queue_manager.assign_tag_by_name(entry_id, channel.strip) if channel && !channel.strip.empty?
      end

      apply_auto_tags(entry_id, url, metadata)
    end

    # @param entry_id [Integer] Queue entry ID
    # @param url [String] URL of the entry
    # @param metadata [Hash] Metadata hash from build_metadata
    # @return [void]
    def apply_auto_tags(entry_id, url, metadata)
      tags = @auto_tagger.tags_for(title: metadata[:title], channel: metadata[:channel], url: url)

      tags.each { |tag_name| @queue_manager.assign_tag_by_name(entry_id, tag_name) }
    end

    # @return [void]
    def notify_metadata_fetched
      return unless @on_metadata_fetched

      @scheduler.call { @on_metadata_fetched.call }
    end
  end
end
