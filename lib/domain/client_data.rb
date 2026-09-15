# frozen_string_literal: true

require 'json'
require 'digest'

module Domain
  # The `clientDataJSON` a passkey ceremony signs over: what kind of ceremony
  # it was, the challenge the site sent, and the origin the browser saw.
  #
  # The site checks all three, so the origin here must be the real one (the
  # Framework's, not the page's) and the challenge must be exactly the text
  # the page supplied.
  module ClientData
    CREATE = 'webauthn.create'
    GET = 'webauthn.get'
    TYPES = [CREATE, GET].freeze

    # @param type [String] CREATE or GET
    # @param challenge [String] The site's challenge, base64url as received
    # @param origin [String] The page's origin (see Domain::WebOrigin)
    # @return [String] JSON
    def self.json(type:, challenge:, origin:)
      raise ArgumentError, "unknown client data type #{type.inspect}" unless TYPES.include?(type)

      JSON.generate('type' => type, 'challenge' => challenge, 'origin' => origin, 'crossOrigin' => false)
    end

    # @param json [String] As returned by `json`
    # @return [String] SHA-256 of the bytes, which is what gets signed
    def self.hash(json)
      Digest::SHA256.digest(json)
    end
  end
end
