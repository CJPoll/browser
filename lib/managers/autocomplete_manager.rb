require_relative '../domain/frecency'
require_relative '../adapters/fzf_adapter'

# AutocompleteManager - Orchestrates URL autocomplete suggestions
#
# This manager coordinates between Managers::HistoryManager (data source),
# Frecency module (scoring), and FzfAdapter (fuzzy filtering) to provide
# relevant URL suggestions as the user types.
#
# Key features:
# - Frecency-based scoring (frequency + recency)
# - Fuzzy search on both titles and URLs
# - 30-second cache to avoid repeated database queries
# - Configurable result limits
#
# @example Basic usage
#   manager = AutocompleteManager.new(history_manager)
#   suggestions = manager.suggest("git")
#   # => [{uri: "https://github.com", title: "GitHub", frecency: 500, ...}, ...]
#
class AutocompleteManager
  # Cache duration in seconds
  CACHE_DURATION = 30

  # Number of candidates to fetch from history
  TOP_CANDIDATES = 500

  # Maximum number of results to return
  RESULT_LIMIT = 10

  # Creates a new AutocompleteManager
  #
  # Owns the clock on behalf of the Frecency domain module, which never reads
  # it. Tests inject a controllable clock to make scoring deterministic.
  #
  # @param history_manager [Managers::HistoryManager] History use cases; supplies
  #   the candidate pages as Domain::Page objects
  # @param clock [#call] Returns the current Time
  def initialize(history_manager, clock: -> { Time.now })
    @history_manager = history_manager
    @clock = clock
    @cache = nil
    @cache_expires_at = 0
  end

  # Returns autocomplete suggestions for a query
  #
  # @param query [String] User's search query
  # @return [Array<Hash>] Matching candidates with :uri, :title, :favicon, :frecency
  def suggest(query)
    candidates = cached_candidates

    # Empty/whitespace query returns top candidates by frecency
    if query.nil? || query.strip.empty?
      return candidates.first(RESULT_LIMIT)
    end

    # Build fzf input: "title\turl" format (searches both fields)
    fzf_input = candidates.map { |c| "#{c[:title] || ''}\t#{c[:uri]}" }

    # Build lookup map for reconstructing candidates from fzf output
    uri_map = candidates.each_with_object({}) { |c, h| h[c[:uri]] = c }

    # Filter using fzf
    filtered = FzfAdapter.filter(fzf_input, query, limit: RESULT_LIMIT)

    # Map fzf output back to candidate hashes
    filtered.map { |line|
      # Extract URL from tab-separated line
      uri = line.split("\t").last
      uri_map[uri]
    }.compact
  end

  # Invalidates the candidate cache
  #
  # Call this when history is updated and you want fresh results immediately.
  # Otherwise, the cache will naturally expire after CACHE_DURATION seconds.
  def invalidate_cache
    @cache_expires_at = 0
  end

  private

  # Returns cached candidates or builds new cache if expired
  #
  # @return [Array<Hash>] Candidates sorted by frecency score
  def cached_candidates
    now = @clock.call.to_i

    if @cache.nil? || now >= @cache_expires_at
      @cache = build_candidates(now)
      @cache_expires_at = now + CACHE_DURATION
    end

    @cache
  end

  # Builds candidate list from history with frecency scores
  #
  # @param now [Integer] Current Unix timestamp
  # @return [Array<Hash>] Candidates sorted by frecency (highest first)
  def build_candidates(now)
    pages = @history_manager.top_pages_by_frecency(TOP_CANDIDATES)

    pages.map do |page|
      {
        uri: page.uri,
        title: page.title,
        favicon: page.favicon,
        frecency: Frecency.score(
          page.visit_count,
          page.last_visited_at&.to_i || 0,
          now
        )
      }
    end.sort_by { |c| -c[:frecency] }
  end
end
