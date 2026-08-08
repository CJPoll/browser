# frozen_string_literal: true

require_relative 'page'

module Domain
  # One visit to a page: the moment the user arrived, and the title the page
  # carried at that moment.
  #
  # A visit keeps its own `title` because a single-page app changes its title
  # without ever creating a new page record -- the title on the visit is what
  # the user actually saw, so it wins when there is one.
  #
  # `page` is the page visited, populated when the query joined it in.
  class Visit
    attr_reader :id, :page_id, :visited_at, :title, :page

    # @param visited_at [Time] When the visit happened -- required; Domain never
    #   reads the clock, so the calling Manager supplies it
    # @param id [Integer, nil] Row id, nil until persisted
    # @param page_id [Integer, nil] Visited page's row id
    # @param title [String, nil] Title the page carried at visit time
    # @param page [Page, nil] The page visited, when the query joined it in
    def initialize(visited_at:, id: nil, page_id: nil, title: nil, page: nil)
      raise ArgumentError, 'visited_at is required' if visited_at.nil?

      @id = id
      @page_id = page_id
      @visited_at = visited_at
      @title = title
      @page = page
      freeze
    end

    # @return [String, nil] URI visited, when the page is populated
    def uri
      page&.uri
    end

    # @return [String, nil] Favicon PNG bytes, when the page is populated
    def favicon
      page&.favicon
    end

    # The text to show for this visit: the title seen at visit time, falling
    # back to the page's current title and then to its URI
    #
    # @return [String, nil]
    def display_title
      title || page&.title || page&.uri
    end

    # Returns a copy with the given attributes replaced
    #
    # @param overrides [Hash] Attributes to change
    # @return [Visit]
    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        id: id,
        page_id: page_id,
        visited_at: visited_at,
        title: title,
        page: page
      }
    end

    def ==(other)
      other.is_a?(Visit) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
