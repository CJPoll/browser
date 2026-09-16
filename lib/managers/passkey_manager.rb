# frozen_string_literal: true

require 'securerandom'
require_relative '../adapters/es256_signer'
require_relative '../adapters/one_password_passkey_store'
require_relative '../domain/passkey_request'
require_relative '../domain/relying_party_id'
require_relative '../domain/passkey_prompt'
require_relative '../domain/passkey_response'
require_relative '../domain/passkey'
require_relative '../domain/client_data'
require_relative '../domain/authenticator_data'
require_relative '../domain/cose_key'
require_relative '../domain/attestation_object'
require_relative '../domain/base64url'

module Managers
  # The browser acting as a WebAuthn authenticator: what to do when a page
  # asks to create a passkey or sign in with one.
  #
  # Two steps, with the user in between. `prepare` checks everything that
  # needs no user and answers with a `Domain::PasskeyPrompt` to show, or a
  # `Domain::PasskeyResponse` rejection to deliver straight away. Once the
  # user has answered, the Framework calls `register`, `authenticate` or
  # `cancel` with the prompt, and gets the response for the page. Nothing is
  # kept here between the two calls.
  #
  # The manager decides, the Framework applies: no widget and no WebKit
  # object is ever seen here, which is what makes every branch testable with
  # a fake store and a fake signer.
  class PasskeyManager
    CREDENTIAL_ID_BYTES = 32
    SECURE_RANDOM = ->(bytes) { SecureRandom.random_bytes(bytes) }

    # @param store [#save, #find_for_rp] Where passkeys are kept
    # @param signer [#generate, #sign] Makes and uses ES256 keys
    # @param clock [#call] Answers the current time
    # @param random [#call] Answers that many random bytes
    def initialize(store: Adapters::OnePasswordPasskeyStore.new,
                   signer: Adapters::Es256Signer.new,
                   clock: -> { Time.now },
                   random: SECURE_RANDOM)
      @store = store
      @signer = signer
      @clock = clock
      @random = random
    end

    # Works out what a page's request needs before the user is asked
    #
    # @param message [String] The JSON the shim posted
    # @param origin [String, nil] The page's origin as the Framework saw it
    # @return [Domain::PasskeyPrompt, Domain::PasskeyResponse, nil] A prompt
    #   to show, a rejection to deliver, or nil when the message is too
    #   broken to answer at all
    def prepare(message, origin:)
      request = Domain::PasskeyRequest.parse(message)
      return declined(request, Domain::PasskeyResponse::NOT_SUPPORTED, 'Conditional mediation is not supported') if request.conditional?

      resolution = Domain::RelyingPartyId.resolve(origin: origin, requested: request.rp_id)
      return declined(request, Domain::PasskeyResponse::SECURITY, "Relying party ID refused: #{resolution.error}") unless resolution.valid?

      stored = @store.find_for_rp(resolution.rp_id)
      request.create? ? prepare_creation(request, origin, resolution.rp_id, stored) : prepare_sign_in(request, origin, resolution.rp_id, stored)
    rescue Domain::PasskeyRequest::Malformed => e
      request_id = Domain::PasskeyRequest.request_id_of(message)
      request_id && Domain::PasskeyResponse.rejected(request_id: request_id, name: Domain::PasskeyResponse::TYPE_ERROR, message: e.message)
    rescue StandardError => e
      store_unavailable(request, e)
    end

    # Creates the passkey the user agreed to
    #
    # @param prompt [Domain::PasskeyPrompt] A creation prompt from `prepare`
    # @return [Domain::PasskeyResponse]
    def register(prompt)
      request = prompt.request
      key_pair = @signer.generate
      credential_id = Domain::Base64Url.encode(@random.call(CREDENTIAL_ID_BYTES))
      passkey = @store.save(Domain::Passkey.new(
        credential_id: credential_id, rp_id: prompt.rp_id, user_handle: request.user_id,
        user_name: request.user_name, user_display_name: request.user_display_name,
        private_key_pem: key_pair.private_key_pem, created_at: @clock.call
      ))

      client_data_json = Domain::ClientData.json(type: Domain::ClientData::CREATE, challenge: request.challenge, origin: prompt.origin)
      authenticator_data = authenticator_data_for(passkey, credential: {
        id: Domain::Base64Url.decode(credential_id),
        cose_public_key: Domain::CoseKey.es256(x: key_pair.x, y: key_pair.y)
      })

      Domain::PasskeyResponse.registered(
        request_id: request.request_id, credential_id: credential_id,
        client_data_json: client_data_json,
        attestation_object: Domain::AttestationObject.none(authenticator_data: authenticator_data),
        authenticator_data: authenticator_data, public_key_der: key_pair.public_key_der
      )
    rescue StandardError => e
      store_unavailable(prompt.request, e)
    end

    # Signs in with the passkey the user chose
    #
    # @param prompt [Domain::PasskeyPrompt] A sign-in prompt from `prepare`
    # @param passkey [Domain::Passkey] One of the prompt's candidates
    # @return [Domain::PasskeyResponse]
    def authenticate(prompt, passkey)
      raise ArgumentError, 'passkey was not offered by this prompt' unless prompt.candidates.include?(passkey)

      request = prompt.request
      client_data_json = Domain::ClientData.json(type: Domain::ClientData::GET, challenge: request.challenge, origin: prompt.origin)
      authenticator_data = authenticator_data_for(passkey)
      signature = @signer.sign(passkey.private_key_pem, authenticator_data + Domain::ClientData.hash(client_data_json))

      Domain::PasskeyResponse.asserted(
        request_id: request.request_id, credential_id: passkey.credential_id,
        client_data_json: client_data_json, authenticator_data: authenticator_data,
        signature: signature, user_handle: passkey.user_handle
      )
    end

    # The user declined
    #
    # @param prompt [Domain::PasskeyPrompt]
    # @return [Domain::PasskeyResponse]
    def cancel(prompt)
      declined(prompt.request, Domain::PasskeyResponse::NOT_ALLOWED, 'The user declined')
    end

    private

    def prepare_creation(request, origin, rp_id, stored)
      unless request.supports_es256?
        return declined(request, Domain::PasskeyResponse::NOT_SUPPORTED, 'Only ES256 keys can be made')
      end
      if stored.any? { |passkey| request.exclude_credential_ids.include?(passkey.credential_id) }
        return declined(request, Domain::PasskeyResponse::INVALID_STATE, 'A passkey for this account already exists in this browser')
      end

      Domain::PasskeyPrompt.new(request: request, origin: origin, rp_id: rp_id)
    end

    def prepare_sign_in(request, origin, rp_id, stored)
      candidates = if request.allow_credential_ids.empty?
                     stored
                   else
                     stored.select { |passkey| request.allow_credential_ids.include?(passkey.credential_id) }
                   end
      if candidates.empty?
        return declined(request, Domain::PasskeyResponse::NOT_ALLOWED, 'No passkey for this site is stored in this browser')
      end

      Domain::PasskeyPrompt.new(request: request, origin: origin, rp_id: rp_id, candidates: candidates)
    end

    # The user unlocked the store (1Password) to get here, which is the user
    # verification WebAuthn asks about; and a key kept there is synced, so it
    # is backed up. Both flags therefore hold for every passkey.
    def authenticator_data_for(passkey, credential: nil)
      Domain::AuthenticatorData.build(
        rp_id: passkey.rp_id, sign_count: passkey.sign_count,
        user_verified: true, backed_up: true, credential: credential
      )
    end

    def declined(request, name, message)
      Domain::PasskeyResponse.rejected(request_id: request.request_id, name: name, message: message)
    end

    def store_unavailable(request, error)
      warn "Passkey store unavailable: #{error.message}"
      declined(request, Domain::PasskeyResponse::NOT_ALLOWED, "Passkey store unavailable: #{error.message}")
    end
  end
end
