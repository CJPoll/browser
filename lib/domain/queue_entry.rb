# frozen_string_literal: true

require 'uri'

module Domain
  # An immutable entry in the read/watch/do queue.
  #
  # The queue is ordered by `position`, a 1-based rank that the repository
  # renumbers on insert, removal and reorder. `added_at` is when the URL was
  # queued; `published_at` is the publication date of the page itself, which
  # the metadata worker fills in later and which stays nil for pages that do
  # not advertise one.
  class QueueEntry
    attr_reader :id, :url, :title, :favicon_data, :position, :added_at, :published_at

    # Schemes the queue accepts. The queue is a reading list of web pages, so a
    # `file://` path or a `mailto:` link is not something it can hold.
    QUEUEABLE_SCHEMES = /^https?$/.freeze

    # Whether a URL is one the queue will accept
    #
    # @param url [String, nil] Candidate URL
    # @return [Boolean]
    def self.queueable_url?(url)
      return false if url.nil?

      begin
        URI.parse(url).scheme =~ QUEUEABLE_SCHEMES ? true : false
      rescue URI::InvalidURIError
        false
      end
    end

    # @param url [String] URL queued -- required
    # @param added_at [Time] When it was queued -- required; Domain never reads
    #   the clock, so the calling Manager supplies it
    # @param id [Integer, nil] Row id, nil until persisted
    # @param title [String, nil] Page title, nil until metadata is fetched
    # @param favicon_data [String, nil] PNG bytes, nil until metadata is fetched
    # @param position [Integer, nil] 1-based rank, nil until persisted
    # @param published_at [Time, nil] Publication date of the page, when known
    def initialize(url:, added_at:, id: nil, title: nil, favicon_data: nil,
                   position: nil, published_at: nil)
      raise ArgumentError, 'url is required' if url.nil? || url.to_s.empty?
      raise ArgumentError, 'added_at is required' if added_at.nil?

      @id = id
      @url = url
      @title = title
      @favicon_data = favicon_data
      @position = position
      @added_at = added_at
      @published_at = published_at
      freeze
    end

    # The text to show for this entry: its title, falling back to the URL for
    # entries queued from a link before the metadata worker has run
    #
    # @return [String]
    def display_title
      title || url
    end

    # Returns a copy with the given attributes replaced
    #
    # @param overrides [Hash] Attributes to change
    # @return [QueueEntry]
    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        id: id,
        url: url,
        title: title,
        favicon_data: favicon_data,
        position: position,
        added_at: added_at,
        published_at: published_at
      }
    end

    def ==(other)
      other.is_a?(QueueEntry) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
