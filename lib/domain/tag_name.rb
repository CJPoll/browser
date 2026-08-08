module Domain
  # Normalization and validation rules for queue tag names.
  #
  # A tag name is stored with its case intact (lookups are case-insensitive at
  # the database level) but with its whitespace normalized, so that
  # "  read   later  " and "read later" are the same tag.
  module TagName
    # Longest permitted normalized name; the tags table enforces the same limit
    MAX_LENGTH = 100

    WHITESPACE_RUN = /\s+/.freeze

    # Normalizes a raw tag name: strips the ends and collapses internal
    # whitespace runs to a single space
    #
    # @param raw [String, nil] Tag name as typed
    # @return [String, nil] Normalized name, or nil if blank
    def self.normalize(raw)
      return nil if raw.nil?

      normalized = raw.strip.gsub(WHITESPACE_RUN, ' ')
      return nil if normalized.empty?

      normalized
    end

    # Checks whether a raw tag name is storable
    #
    # @param raw [String, nil] Tag name as typed
    # @return [Boolean] true if the name is non-blank and within the length limit
    def self.valid?(raw)
      normalized = normalize(raw)
      return false unless normalized

      normalized.length <= MAX_LENGTH
    end
  end
end
