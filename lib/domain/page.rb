# frozen_string_literal: true

module Domain
  # A page in the browsing history: one record per distinct URI, carrying the
  # aggregate counters (`visit_count`, `last_visited_at`) that individual visits
  # roll up into, plus the favicon shown next to it in the sidebar.
  #
  # Only `uri` is required. History is queried through several projections --
  # a search result knows nothing about the favicon, the autocomplete candidate
  # query selects no id -- so a Page may be partially populated. Ask for what
  # the query you called promises; `HistoryRepository` documents each one.
  class Page
    attr_reader :id, :site_id, :uri, :title, :favicon, :created_at,
                :last_visited_at, :visit_count

    # @param uri [String] Page URI -- required
    # @param id [Integer, nil] Row id, nil when unpersisted or unprojected
    # @param site_id [Integer, nil] Owning site's row id
    # @param title [String, nil] Page title, nil until one is recorded
    # @param favicon [String, nil] PNG bytes, nil until one is fetched
    # @param created_at [Time, nil] When the page was first visited
    # @param last_visited_at [Time, nil] When the page was last visited
    # @param visit_count [Integer] How many visits have been recorded
    def initialize(uri:, id: nil, site_id: nil, title: nil, favicon: nil,
                   created_at: nil, last_visited_at: nil, visit_count: 0)
      raise ArgumentError, 'uri is required' if uri.nil? || uri.to_s.empty?

      @id = id
      @site_id = site_id
      @uri = uri
      @title = title
      @favicon = favicon
      @created_at = created_at
      @last_visited_at = last_visited_at
      @visit_count = visit_count
      freeze
    end

    # The text to show for this page: its title, falling back to the URI for
    # pages recorded before a title arrived
    #
    # @return [String]
    def display_title
      title || uri
    end

    # Returns a copy with the given attributes replaced
    #
    # @param overrides [Hash] Attributes to change
    # @return [Page]
    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        id: id,
        site_id: site_id,
        uri: uri,
        title: title,
        favicon: favicon,
        created_at: created_at,
        last_visited_at: last_visited_at,
        visit_count: visit_count
      }
    end

    def ==(other)
      other.is_a?(Page) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
