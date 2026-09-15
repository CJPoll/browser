# frozen_string_literal: true

require 'digest'

module Domain
  # The `authenticatorData` byte string every passkey response carries:
  #
  #   rpIdHash (32) | flags (1) | signCount (4) | attestedCredentialData?
  #
  # where the attested credential data (only on registration) is
  #
  #   aaguid (16) | credentialIdLength (2) | credentialId | COSE public key
  #
  # This is the one place the layout is spelled out; the manager only decides
  # which flags are true.
  module AuthenticatorData
    USER_PRESENT = 0x01
    USER_VERIFIED = 0x04
    BACKUP_ELIGIBLE = 0x08
    BACKED_UP = 0x10
    ATTESTED_CREDENTIAL = 0x40

    # No AAGUID: this authenticator makes no claim about its make and model,
    # which is what `none` attestation means.
    AAGUID = ("\x00" * 16).b.freeze
    MAX_CREDENTIAL_ID_BYTES = 1023

    # @param rp_id [String] The relying-party ID the response is scoped to
    # @param sign_count [Integer] Signature counter
    # @param user_verified [Boolean] Whether the user verified (not merely
    #   proved presence)
    # @param backed_up [Boolean] Whether the key is synced elsewhere; a synced
    #   key is by definition both eligible for backup and backed up
    # @param credential [Hash, nil] `{ id:, cose_public_key: }` on registration
    # @return [String] Binary
    def self.build(rp_id:, sign_count:, user_verified:, backed_up:, credential: nil)
      raise ArgumentError, 'rp_id is required' if rp_id.nil? || rp_id.empty?

      flags = USER_PRESENT
      flags |= USER_VERIFIED if user_verified
      flags |= BACKUP_ELIGIBLE | BACKED_UP if backed_up
      flags |= ATTESTED_CREDENTIAL if credential

      data = Digest::SHA256.digest(rp_id) + [flags].pack('C') + [sign_count].pack('N')
      data += attested_credential_data(credential) if credential
      data.b
    end

    def self.attested_credential_data(credential)
      id = credential.fetch(:id).to_s.b
      key = credential.fetch(:cose_public_key).to_s.b
      raise ArgumentError, 'credential id is required' if id.empty?
      raise ArgumentError, "credential id longer than #{MAX_CREDENTIAL_ID_BYTES} bytes" if id.bytesize > MAX_CREDENTIAL_ID_BYTES
      raise ArgumentError, 'public key is required' if key.empty?

      AAGUID + [id.bytesize].pack('n') + id + key
    end
    private_class_method :attested_credential_data
  end
end
