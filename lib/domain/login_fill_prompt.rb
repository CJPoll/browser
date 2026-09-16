# frozen_string_literal: true

module Domain
  # What the user is asked before a login is filled: the site, and the
  # candidate accounts to choose from. Carries everything the finishing call
  # needs, so the manager keeps no state between offering and filling.
  #
  # An empty candidate list is never a prompt -- that is a
  # Domain::LoginFillNotice (`:no_matches`).
  class LoginFillPrompt
    attr_reader :origin, :site_key, :candidates

    # @param origin [String]
    # @param site_key [String]
    # @param candidates [Array<Domain::LoginCandidate>] non-empty
    def initialize(origin:, site_key:, candidates:)
      raise ArgumentError, 'origin is required' if origin.nil? || origin.to_s.empty?
      raise ArgumentError, 'site_key is required' if site_key.nil? || site_key.to_s.empty?
      raise ArgumentError, 'candidates must not be empty' if candidates.nil? || candidates.empty?

      @origin = origin
      @site_key = site_key
      @candidates = candidates.dup.freeze
      freeze
    end

    # @return [Boolean] whether there is more than one account to choose from
    def choice_needed?
      candidates.length > 1
    end

    # @return [Array<String>]
    def candidate_labels
      candidates.map(&:label)
    end

    # @param index [Integer]
    # @return [Domain::LoginCandidate]
    # @raise [ArgumentError] for an out-of-range, negative or non-integer index
    def candidate_at(index)
      unless index.is_a?(Integer) && index >= 0 && index < candidates.length
        raise ArgumentError, "no candidate at #{index}"
      end

      candidates[index]
    end

    # @return [String]
    def message
      if choice_needed?
        "Fill the login for #{site_key} -- choose an account"
      else
        "Fill the login for #{site_key} with #{candidates.first.label}?"
      end
    end

    # @return [Hash]
    def to_h
      { origin: origin, site_key: site_key, candidates: candidates }
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
