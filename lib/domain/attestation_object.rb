# frozen_string_literal: true

require 'cbor'

module Domain
  # The attestation object a registration returns: the authenticator data
  # wrapped with a statement about the authenticator's provenance.
  #
  # This browser makes no such statement -- format `none`, an empty
  # statement -- which every relying party accepts and which is what synced
  # passkey providers send too.
  module AttestationObject
    FORMAT_NONE = 'none'

    # @param authenticator_data [String] See Domain::AuthenticatorData
    # @return [String] CBOR, in CTAP2 canonical key order
    def self.none(authenticator_data:)
      data = authenticator_data.to_s.b
      raise ArgumentError, 'authenticator data is required' if data.empty?

      # Insertion order is encoding order; "fmt", "attStmt", "authData" are
      # already in canonical (shortest key first) order.
      CBOR.encode('fmt' => FORMAT_NONE, 'attStmt' => {}, 'authData' => data)
    end
  end
end
