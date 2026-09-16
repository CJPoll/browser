# frozen_string_literal: true

module Domain
  # How many queue entries carry a given tag.
  #
  # Produced for the filter popover, which now lists only tags in use -- carried
  # by at least one queue entry (see Managers::QueueManager#tags_in_use) -- with
  # its count alongside.
  class TagUsage
    attr_reader :tag, :count

    # @param tag [Domain::Tag] The tag being counted
    # @param count [Integer] Number of queue entries carrying it
    def initialize(tag:, count:)
      raise ArgumentError, 'tag is required' if tag.nil?
      raise ArgumentError, 'count is required' if count.nil?

      @tag = tag
      @count = count
      freeze
    end

    # @return [String] Tag name, for display
    def name
      tag.name
    end

    # @return [Integer, nil] Tag id, for filter selection
    def tag_id
      tag.id
    end

    # @return [Boolean] Whether any queue entry currently carries this tag
    def in_use?
      count.positive?
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { tag: tag, count: count }
    end

    def ==(other)
      other.is_a?(TagUsage) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
