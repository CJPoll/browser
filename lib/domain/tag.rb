# frozen_string_literal: true

module Domain
  # An immutable queue tag.
  #
  # Names are stored with their case intact but are compared
  # case-insensitively -- the tags table declares `COLLATE NOCASE`, and
  # `Domain::TagName` normalizes whitespace before a name reaches it. Value
  # equality here is exact, so two tags differing only in case are different
  # values; use `same_name?` to ask the case-insensitive question.
  class Tag
    attr_reader :id, :name

    # @param name [String] Tag name -- required, already normalized
    # @param id [Integer, nil] Row id, nil until persisted
    def initialize(name:, id: nil)
      raise ArgumentError, 'name is required' if name.nil? || name.to_s.empty?

      @id = id
      @name = name
      freeze
    end

    # Compares names the way the database does
    #
    # @param other_name [String, nil] Name to compare against
    # @return [Boolean]
    def same_name?(other_name)
      return false if other_name.nil?

      name.casecmp(other_name).zero?
    end

    # Returns a copy carrying the id assigned by the repository
    #
    # @param id [Integer] Row id
    # @return [Tag]
    def with_id(id)
      self.class.new(id: id, name: name)
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { id: id, name: name }
    end

    def ==(other)
      other.is_a?(Tag) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
