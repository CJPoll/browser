# frozen_string_literal: true

require 'uri'
require_relative '../domain/url_host'
require_relative '../repositories/history_repository'

module Managers
  # Recording and querying the browsing history.
  #
  # The manager owns two things the repository must not:
  #
  # - **the clock**, so that a visit's timestamp is injectable in tests; and
  # - **the deduplication policy**. WebKit reports a page arriving several
  #   times -- `load-changed` fires, then `notify::title` fires again once a
  #   single-page app has rewritten the title -- and each report would otherwise
  #   become a separate visit. The manager remembers the last URL/title pair it
  #   recorded and refuses an identical repeat. This lived in `BrowserWindow`,
  #   which meant every new caller had to remember to re-implement it.
  #
  # `record_visit` returns a symbol rather than a boolean because the caller
  # acts differently on each outcome: a fresh visit is also when the favicon is
  # worth fetching, a duplicate is a no-op, and an unusable URL is neither.
  class HistoryManager
    def initialize(repository: nil, clock: -> { Time.now })
      @repository = repository || Repositories::HistoryRepository.new
      @clock = clock
      @last_recorded_visit = nil
    end

    # Records an arrival at a URL, unless it repeats the last one recorded
    #
    # @param url [String, nil] URL arrived at
    # @param title [String, nil] Title the page carries right now
    # @param favicon_data [String, nil] PNG bytes, when already known
    # @return [Symbol] `:recorded`, `:duplicate` or `:invalid_url`
    def record_visit(url, title = nil, favicon_data: nil)
      return :invalid_url if url.nil? || url.to_s.empty?

      key = visit_key(url, title)
      return :duplicate if key == @last_recorded_visit

      # Recorded even when the URL turns out to be unusable: a page that cannot
      # be recorded once cannot be recorded on the next identical report either,
      # and retrying would warn on every WebKit signal.
      @last_recorded_visit = key

      authority = authority_for(url)
      return :invalid_url unless authority

      @repository.record_visit(url: url, authority: authority, title: title,
                               favicon_data: favicon_data, now: @clock.call)
      :recorded
    end

    # Stores a favicon for a page already in the history
    #
    # @param url [String, nil] URI of the page
    # @param favicon_data [String, nil] PNG bytes
    # @return [Boolean] True if a page was updated
    def update_favicon(url, favicon_data)
      return false unless url && favicon_data
      return false unless parse(url)

      @repository.update_favicon(url, favicon_data)
    end

    # @param limit [Integer] Maximum number of visits
    # @return [Array<Domain::Visit>] Visits, newest first
    def recent_visits(limit = Repositories::HistoryRepository::DEFAULT_VISIT_LIMIT)
      @repository.recent_visits(limit)
    end

    # @param query [String] Substring to look for in URI, title or site
    # @param limit [Integer] Maximum number of pages
    # @return [Array<Domain::Page>] Matching pages, most recently visited first
    def search(query, limit = Repositories::HistoryRepository::DEFAULT_SEARCH_LIMIT)
      @repository.search(query, limit)
    end

    # @param limit [Integer] Maximum number of candidates
    # @return [Array<Domain::Page>] Autocomplete candidates, roughly ranked
    def top_pages_by_frecency(limit = Repositories::HistoryRepository::DEFAULT_CANDIDATE_LIMIT)
      @repository.top_pages_by_frecency(limit)
    end

    # @param visit_id [Integer, nil] Visit to forget
    # @return [Boolean] True if a visit was deleted
    def delete_visit(visit_id)
      @repository.delete_visit(visit_id)
    end

    # @return [void]
    def close
      @repository.close
    end

    private

    # What makes two reports of the same arrival identical. The title is part
    # of it: a single-page app that swaps its title has genuinely moved on, and
    # that is worth a second visit record.
    def visit_key(url, title)
      "#{url}|#{title}"
    end

    def authority_for(url)
      uri = parse(url)
      return nil unless uri

      Domain::UrlHost.authority(uri)
    end

    def parse(url)
      URI.parse(url)
    rescue URI::InvalidURIError => e
      warn "Invalid URI: #{url} - #{e.message}"
      nil
    end
  end
end
