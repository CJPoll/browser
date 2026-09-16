# frozen_string_literal: true

require 'json'
require_relative 'base64url'

module Domain
  # What the browser tells the page once a passkey request is settled: a
  # credential the shim turns into a `PublicKeyCredential`, or the name of
  # the `DOMException` to reject the page's promise with.
  #
  # Like `PasskeyRequest`, this is the wire format between browser and page,
  # so its shape (and the base64url encoding of every byte field) is decided
  # here and nowhere else.
  class PasskeyResponse
    NOT_ALLOWED = 'NotAllowedError'
    SECURITY = 'SecurityError'
    NOT_SUPPORTED = 'NotSupportedError'
    INVALID_STATE = 'InvalidStateError'
    TYPE_ERROR = 'TypeError'

    ES256 = -7
    # This browser is a platform authenticator: the key never leaves it.
    TRANSPORTS = ['internal'].freeze

    attr_reader :request_id, :credential, :error_name, :error_message

    # A successful registration
    #
    # @param request_id [String] The shim's id for the request
    # @param credential_id [String] base64url
    # @param client_data_json [String] See Domain::ClientData
    # @param attestation_object [String] See Domain::AttestationObject
    # @param authenticator_data [String] See Domain::AuthenticatorData
    # @param public_key_der [String] SubjectPublicKeyInfo DER, for `getPublicKey()`
    # @return [PasskeyResponse]
    def self.registered(request_id:, credential_id:, client_data_json:, attestation_object:,
                        authenticator_data:, public_key_der:)
      new(request_id: request_id, credential: {
        'id' => credential_id,
        'clientDataJSON' => Base64Url.encode(client_data_json),
        'attestationObject' => Base64Url.encode(attestation_object),
        'authenticatorData' => Base64Url.encode(authenticator_data),
        'publicKey' => Base64Url.encode(public_key_der),
        'publicKeyAlgorithm' => ES256,
        'transports' => TRANSPORTS
      })
    end

    # A successful sign-in
    #
    # @param request_id [String] The shim's id for the request
    # @param credential_id [String] base64url
    # @param client_data_json [String] See Domain::ClientData
    # @param authenticator_data [String] See Domain::AuthenticatorData
    # @param signature [String] DER-encoded ECDSA signature
    # @param user_handle [String] base64url, as the site supplied it
    # @return [PasskeyResponse]
    def self.asserted(request_id:, credential_id:, client_data_json:, authenticator_data:,
                      signature:, user_handle:)
      new(request_id: request_id, credential: {
        'id' => credential_id,
        'clientDataJSON' => Base64Url.encode(client_data_json),
        'authenticatorData' => Base64Url.encode(authenticator_data),
        'signature' => Base64Url.encode(signature),
        'userHandle' => user_handle
      })
    end

    # A request that will not be fulfilled
    #
    # @param request_id [String] The shim's id for the request
    # @param name [String] One of the DOMException name constants
    # @param message [String] Shown to the page, not the user
    # @return [PasskeyResponse]
    def self.rejected(request_id:, name:, message:)
      raise ArgumentError, 'error name is required' if name.nil? || name.empty?

      new(request_id: request_id, error_name: name, error_message: message.to_s)
    end

    def initialize(request_id:, credential: nil, error_name: nil, error_message: nil)
      raise ArgumentError, 'request_id is required' if request_id.nil? || request_id.empty?

      @request_id = request_id
      @credential = credential&.freeze
      @error_name = error_name
      @error_message = error_message
      freeze
    end

    def resolved?
      !credential.nil?
    end

    def rejected?
      credential.nil?
    end

    # @return [Hash] The message the shim receives
    def to_h
      if resolved?
        { 'id' => request_id, 'ok' => true, 'credential' => credential }
      else
        { 'id' => request_id, 'ok' => false, 'error' => { 'name' => error_name, 'message' => error_message } }
      end
    end

    # @return [String] JSON
    def to_json(*)
      JSON.generate(to_h)
    end

    def ==(other)
      other.is_a?(PasskeyResponse) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
