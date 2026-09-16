# frozen_string_literal: true

require 'public_suffix'
require_relative 'web_origin'

module Domain
  # Which relying-party ID a page may create or use passkeys for.
  #
  # WebAuthn scopes every passkey to an RP ID, and a page may only ask for an
  # RP ID that is its own host or a registrable parent of it
  # (`accounts.google.com` may ask for `google.com`; `evil.example` may not,
  # and nobody may ask for `co.uk`). Getting this wrong hands one site's
  # passkeys to another, so the rule lives here with exhaustive tests and the
  # manager never re-derives it.
  #
  # The public-suffix check follows browsers: a requested ID that is itself a
  # public suffix (`co.uk`, `github.io`) is refused even though it is a
  # suffix of the host.
  module RelyingPartyId
    INSECURE_ORIGIN = :insecure_origin
    NOT_A_SUFFIX = :not_a_suffix
    PUBLIC_SUFFIX = :public_suffix

    # The answer: either an RP ID or the reason there is none.
    class Result
      attr_reader :rp_id, :error

      # @param rp_id [String, nil]
      # @param error [Symbol, nil]
      def initialize(rp_id: nil, error: nil)
        @rp_id = rp_id
        @error = error
        freeze
      end

      # @return [Boolean]
      def valid?
        !rp_id.nil?
      end

      # @return [Hash] Every attribute, for comparison and inspection
      def to_h
        { rp_id: rp_id, error: error }
      end

      def ==(other)
        other.is_a?(Result) && other.to_h == to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end
    end

    # @param origin [String, nil] The page's origin (see Domain::WebOrigin)
    # @param requested [String, nil] The RP ID the page asked for, if any
    # @return [Result]
    def self.resolve(origin:, requested: nil)
      return Result.new(error: INSECURE_ORIGIN) unless WebOrigin.secure?(origin)

      host = WebOrigin.host(origin)
      requested = requested.to_s.strip.downcase
      return Result.new(rp_id: host) if requested.empty? || requested == host
      return Result.new(error: NOT_A_SUFFIX) unless host.end_with?(".#{requested}")
      return Result.new(error: PUBLIC_SUFFIX) unless registrable?(requested)

      Result.new(rp_id: requested)
    end

    # @param domain [String]
    # @return [Boolean] true if the domain is registrable (has a label below
    #   the public suffix), so a passkey scoped to it belongs to one owner
    def self.registrable?(domain)
      PublicSuffix.valid?(domain, default_rule: nil)
    end
    private_class_method :registrable?
  end
end
