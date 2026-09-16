# frozen_string_literal: true

module Domain
  # What the user is asked before a passkey is created or used: which site,
  # which account, and -- when signing in -- which of their passkeys.
  #
  # The manager builds one of these once a request has passed every check
  # that needs no user, and the Framework hands it back (with the user's
  # choice) to finish the ceremony. Everything needed to finish is on it, so
  # the manager keeps no pending state.
  class PasskeyPrompt
    attr_reader :request, :origin, :rp_id, :candidates

    # @param request [Domain::PasskeyRequest] What the page asked for
    # @param origin [String] The page's origin, as seen by the Framework
    # @param rp_id [String] The relying-party ID the request resolved to
    # @param candidates [Array<Domain::Passkey>] Stored passkeys that could
    #   answer a sign-in request; empty for a creation request
    def initialize(request:, origin:, rp_id:, candidates: [])
      raise ArgumentError, 'request is required' if request.nil?
      raise ArgumentError, 'origin is required' if origin.nil? || origin.empty?
      raise ArgumentError, 'rp_id is required' if rp_id.nil? || rp_id.empty?

      @request = request
      @origin = origin
      @rp_id = rp_id
      @candidates = candidates.dup.freeze
      freeze
    end

    def request_id
      request.request_id
    end

    def create?
      request.create?
    end

    def get?
      request.get?
    end

    # Whether the user has to pick between passkeys before signing in
    #
    # @return [Boolean]
    def choice_needed?
      candidates.length > 1
    end

    # @return [Array<String>] One label per candidate, in candidate order
    def candidate_labels
      candidates.map(&:user_label)
    end

    # @return [String] What the consent bar says
    def message
      if create?
        "#{rp_id} wants to create a passkey for #{request.user_label}"
      elsif choice_needed?
        "Sign in to #{rp_id} -- choose a passkey"
      else
        "Sign in to #{rp_id} with your passkey for #{candidates.first.user_label}"
      end
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { request: request, origin: origin, rp_id: rp_id, candidates: candidates }
    end

    def ==(other)
      other.is_a?(PasskeyPrompt) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
