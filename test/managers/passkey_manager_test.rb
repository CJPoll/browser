require 'minitest/autorun'
require 'json'
require 'cbor'
require 'digest'
require_relative '../support/test_clock'
require_relative '../../lib/managers/passkey_manager'
require_relative '../../lib/adapters/es256_signer'
require_relative '../../lib/domain/base64url'

class ManagersPasskeyManagerTest < Minitest::Test
  ORIGIN = 'https://accounts.example.com'.freeze
  NOW = Time.at(1_700_000_000).freeze
  CHALLENGE = 'Y2hhbGxlbmdl'.freeze
  USER_ID = 'dXNlci0x'.freeze

  # In-memory stand-in for the 1Password store.
  class FakeStore
    attr_reader :saved

    def initialize(passkeys = [], failing: false)
      @passkeys = passkeys.dup
      @saved = []
      @failing = failing
      @next_id = 0
    end

    def save(passkey)
      raise StandardError, 'not signed in' if @failing

      saved = passkey.with(store_id: "item-#{@next_id += 1}")
      @saved << saved
      @passkeys << saved
      saved
    end

    def find_for_rp(rp_id)
      raise StandardError, 'not signed in' if @failing

      @passkeys.select { |passkey| passkey.rp_id == rp_id }
    end
  end

  # Deterministic keys and signatures, and a record of what was signed.
  class FakeSigner
    X = ("\xAA" * 32).b.freeze
    Y = ("\xBB" * 32).b.freeze

    attr_reader :signed

    def initialize
      @generated = 0
      @signed = []
    end

    def generate
      @generated += 1
      Adapters::Es256Signer::KeyPair.new(
        private_key_pem: "pem-#{@generated}", public_key_der: "der-#{@generated}".b, x: X, y: Y
      )
    end

    def sign(private_key_pem, data)
      @signed << [private_key_pem, data]
      "signature-with-#{private_key_pem}".b
    end
  end

  def setup
    @store = FakeStore.new
    @signer = FakeSigner.new
    @clock = TestClock.new(NOW)
    @manager = build_manager(store: @store)
  end

  def build_manager(store:)
    Managers::PasskeyManager.new(store: store, signer: @signer, clock: @clock, random: ->(bytes) { ("\x07" * bytes).b })
  end

  def create_message(id: 'passkey-1', mediation: 'optional', **options)
    JSON.generate(
      'id' => id, 'op' => 'create', 'mediation' => mediation,
      'options' => {
        'rp' => { 'name' => 'Example' },
        'user' => { 'id' => USER_ID, 'name' => 'cody@example.com', 'displayName' => 'Cody' },
        'challenge' => CHALLENGE,
        'pubKeyCredParams' => [{ 'type' => 'public-key', 'alg' => -7 }]
      }.merge(options)
    )
  end

  def get_message(id: 'passkey-2', mediation: 'optional', **options)
    JSON.generate(
      'id' => id, 'op' => 'get', 'mediation' => mediation,
      'options' => { 'challenge' => CHALLENGE }.merge(options)
    )
  end

  def stored_passkey(credential_id: 'Y3JlZC0x', rp_id: 'accounts.example.com', user_name: 'cody@example.com')
    Domain::Passkey.new(credential_id: credential_id, rp_id: rp_id, user_handle: USER_ID, user_name: user_name,
                        private_key_pem: "pem-for-#{credential_id}", created_at: NOW, store_id: "item-#{credential_id}")
  end

  def assert_rejected(result, name)
    assert_kind_of Domain::PasskeyResponse, result
    assert result.rejected?, "expected a rejection, got #{result.inspect}"
    assert_equal name, result.error_name
  end

  # === prepare: creation ===

  def test_a_creation_request_becomes_a_prompt_scoped_to_the_origin_host
    prompt = @manager.prepare(create_message, origin: ORIGIN)

    assert_kind_of Domain::PasskeyPrompt, prompt
    assert prompt.create?
    assert_equal 'accounts.example.com', prompt.rp_id
    assert_equal ORIGIN, prompt.origin
    assert_equal 'passkey-1', prompt.request_id
  end

  def test_a_creation_request_may_be_scoped_to_a_registrable_parent
    prompt = @manager.prepare(create_message('rp' => { 'id' => 'example.com' }), origin: ORIGIN)

    assert_equal 'example.com', prompt.rp_id
  end

  def test_a_creation_request_for_an_unrelated_rp_is_a_security_error
    result = @manager.prepare(create_message('rp' => { 'id' => 'evil.example' }), origin: ORIGIN)

    assert_rejected result, 'SecurityError'
  end

  def test_a_request_from_an_insecure_origin_is_a_security_error
    assert_rejected @manager.prepare(create_message, origin: 'http://accounts.example.com'), 'SecurityError'
  end

  def test_a_request_from_no_origin_is_a_security_error
    assert_rejected @manager.prepare(create_message, origin: nil), 'SecurityError'
  end

  def test_a_creation_request_the_signer_cannot_satisfy_is_not_supported
    message = create_message('pubKeyCredParams' => [{ 'type' => 'public-key', 'alg' => -257 }])

    assert_rejected @manager.prepare(message, origin: ORIGIN), 'NotSupportedError'
  end

  def test_a_creation_request_excluding_a_passkey_stored_here_is_an_invalid_state
    manager = build_manager(store: FakeStore.new([stored_passkey(credential_id: 'Y3JlZC0x')]))
    message = create_message('excludeCredentials' => [{ 'type' => 'public-key', 'id' => 'Y3JlZC0x' }])

    assert_rejected manager.prepare(message, origin: ORIGIN), 'InvalidStateError'
  end

  def test_an_exclusion_list_naming_other_passkeys_does_not_block_creation
    manager = build_manager(store: FakeStore.new([stored_passkey(credential_id: 'Y3JlZC0x')]))
    message = create_message('excludeCredentials' => [{ 'type' => 'public-key', 'id' => 'b3RoZXI' }])

    assert_kind_of Domain::PasskeyPrompt, manager.prepare(message, origin: ORIGIN)
  end

  # === prepare: sign-in ===

  def test_a_sign_in_request_offers_every_passkey_stored_for_the_rp
    mine = stored_passkey(credential_id: 'Y3JlZC0x', user_name: 'cody@example.com')
    work = stored_passkey(credential_id: 'Y3JlZC0y', user_name: 'work@example.com')
    elsewhere = stored_passkey(credential_id: 'Y3JlZC0z', rp_id: 'other.example')
    manager = build_manager(store: FakeStore.new([mine, work, elsewhere]))

    prompt = manager.prepare(get_message, origin: ORIGIN)

    assert prompt.get?
    assert_equal [mine, work], prompt.candidates
  end

  def test_a_sign_in_request_narrows_the_candidates_to_the_allowed_credentials
    mine = stored_passkey(credential_id: 'Y3JlZC0x')
    work = stored_passkey(credential_id: 'Y3JlZC0y')
    manager = build_manager(store: FakeStore.new([mine, work]))
    message = get_message('allowCredentials' => [{ 'type' => 'public-key', 'id' => 'Y3JlZC0y' }])

    assert_equal [work], manager.prepare(message, origin: ORIGIN).candidates
  end

  def test_a_sign_in_request_uses_the_requested_rp_id_to_find_passkeys
    parent = stored_passkey(credential_id: 'Y3JlZC0x', rp_id: 'example.com')
    manager = build_manager(store: FakeStore.new([parent]))

    prompt = manager.prepare(get_message('rpId' => 'example.com'), origin: ORIGIN)

    assert_equal 'example.com', prompt.rp_id
    assert_equal [parent], prompt.candidates
  end

  def test_a_sign_in_request_with_nothing_stored_is_not_allowed
    assert_rejected @manager.prepare(get_message, origin: ORIGIN), 'NotAllowedError'
  end

  def test_a_sign_in_request_allowing_only_unknown_credentials_is_not_allowed
    manager = build_manager(store: FakeStore.new([stored_passkey(credential_id: 'Y3JlZC0x')]))
    message = get_message('allowCredentials' => [{ 'type' => 'public-key', 'id' => 'b3RoZXI' }])

    assert_rejected manager.prepare(message, origin: ORIGIN), 'NotAllowedError'
  end

  # === prepare: requests not worth a prompt ===

  def test_a_conditional_request_is_declined_without_a_prompt
    # The silent autofill probe a login form fires on load.
    assert_rejected @manager.prepare(get_message(mediation: 'conditional'), origin: ORIGIN), 'NotSupportedError'
  end

  def test_a_malformed_request_with_an_id_is_a_type_error
    message = JSON.generate('id' => 'passkey-7', 'op' => 'create', 'options' => {})

    result = @manager.prepare(message, origin: ORIGIN)

    assert_rejected result, 'TypeError'
    assert_equal 'passkey-7', result.request_id
  end

  def test_a_message_with_no_request_id_cannot_be_answered
    assert_nil @manager.prepare('not json', origin: ORIGIN)
  end

  def test_a_store_that_cannot_be_reached_is_not_allowed_and_warned_about
    manager = build_manager(store: FakeStore.new(failing: true))

    result = nil
    assert_output(nil, /not signed in/) { result = manager.prepare(get_message, origin: ORIGIN) }

    assert_rejected result, 'NotAllowedError'
  end

  # === register ===

  def register
    @manager.register(@manager.prepare(create_message, origin: ORIGIN))
  end

  def test_register_stores_a_passkey_for_the_request_user_at_the_current_time
    register

    saved = @store.saved.first
    assert_equal 'accounts.example.com', saved.rp_id
    assert_equal USER_ID, saved.user_handle
    assert_equal 'cody@example.com', saved.user_name
    assert_equal 'Cody', saved.user_display_name
    assert_equal 'pem-1', saved.private_key_pem
    assert_equal NOW, saved.created_at
  end

  def test_register_makes_a_32_byte_random_credential_id
    register

    assert_equal ("\x07" * 32).b, Domain::Base64Url.decode(@store.saved.first.credential_id)
  end

  def test_register_answers_with_the_credential_the_page_expects
    response = register

    assert response.resolved?
    assert_equal 'passkey-1', response.request_id
    assert_equal @store.saved.first.credential_id, response.credential['id']
    assert_equal 'der-1'.b, Domain::Base64Url.decode(response.credential['publicKey'])
  end

  def test_register_binds_the_client_data_to_the_ceremony_challenge_and_origin
    response = register

    client_data = JSON.parse(Domain::Base64Url.decode(response.credential['clientDataJSON']))
    assert_equal({ 'type' => 'webauthn.create', 'challenge' => CHALLENGE, 'origin' => ORIGIN, 'crossOrigin' => false }, client_data)
  end

  def test_register_attests_the_new_key_as_a_verified_backed_up_credential
    response = register
    authenticator_data = Domain::Base64Url.decode(response.credential['authenticatorData'])

    assert_equal Digest::SHA256.digest('accounts.example.com'), authenticator_data[0, 32]
    assert_equal 0x01 | 0x04 | 0x08 | 0x10 | 0x40, authenticator_data.getbyte(32), 'UP, UV, BE, BS, AT'
    assert_equal "\x00\x00\x00\x00".b, authenticator_data[33, 4], 'sign count is zero'
    assert_equal ("\x00" * 16).b, authenticator_data[37, 16], 'no AAGUID'
    assert_equal "\x00\x20".b, authenticator_data[53, 2], '32-byte credential id'
    assert_equal ("\x07" * 32).b, authenticator_data[55, 32]
    assert_equal({ 1 => 2, 3 => -7, -1 => 1, -2 => FakeSigner::X, -3 => FakeSigner::Y }, CBOR.decode(authenticator_data[87..]))
  end

  def test_register_wraps_the_authenticator_data_in_a_none_attestation
    response = register

    attestation = CBOR.decode(Domain::Base64Url.decode(response.credential['attestationObject']))
    assert_equal 'none', attestation['fmt']
    assert_equal({}, attestation['attStmt'])
    assert_equal Domain::Base64Url.decode(response.credential['authenticatorData']), attestation['authData']
  end

  def test_register_is_not_allowed_when_the_store_refuses_the_key
    prompt = @manager.prepare(create_message, origin: ORIGIN)
    manager = build_manager(store: FakeStore.new(failing: true))

    result = nil
    assert_output(nil, /not signed in/) { result = manager.register(prompt) }

    assert_rejected result, 'NotAllowedError'
    assert_equal 'passkey-1', result.request_id
  end

  # === authenticate ===

  def authenticate(passkey = nil)
    manager = build_manager(store: FakeStore.new([stored_passkey]))
    prompt = manager.prepare(get_message, origin: ORIGIN)
    manager.authenticate(prompt, passkey || prompt.candidates.first)
  end

  def test_authenticate_signs_the_authenticator_data_and_client_data_hash_with_the_chosen_key
    response = authenticate

    pem, signed = @signer.signed.first
    assert_equal 'pem-for-Y3JlZC0x', pem
    authenticator_data = Domain::Base64Url.decode(response.credential['authenticatorData'])
    client_data_json = Domain::Base64Url.decode(response.credential['clientDataJSON'])
    assert_equal authenticator_data + Digest::SHA256.digest(client_data_json), signed
    assert_equal 'signature-with-pem-for-Y3JlZC0x'.b, Domain::Base64Url.decode(response.credential['signature'])
  end

  def test_authenticate_answers_with_the_chosen_credential_and_its_user_handle
    response = authenticate

    assert response.resolved?
    assert_equal 'passkey-2', response.request_id
    assert_equal 'Y3JlZC0x', response.credential['id']
    assert_equal USER_ID, response.credential['userHandle']
  end

  def test_authenticate_binds_the_client_data_to_the_sign_in_ceremony
    response = authenticate

    client_data = JSON.parse(Domain::Base64Url.decode(response.credential['clientDataJSON']))
    assert_equal({ 'type' => 'webauthn.get', 'challenge' => CHALLENGE, 'origin' => ORIGIN, 'crossOrigin' => false }, client_data)
  end

  def test_authenticate_reports_a_verified_backed_up_key_with_no_attested_credential
    response = authenticate
    authenticator_data = Domain::Base64Url.decode(response.credential['authenticatorData'])

    assert_equal 37, authenticator_data.bytesize
    assert_equal 0x01 | 0x04 | 0x08 | 0x10, authenticator_data.getbyte(32), 'UP, UV, BE, BS'
  end

  def test_authenticate_refuses_a_passkey_that_was_not_offered
    assert_raises(ArgumentError) { authenticate(stored_passkey(credential_id: 'c29tZXRoaW5n')) }
  end

  # === cancel ===

  def test_cancel_is_not_allowed
    prompt = @manager.prepare(create_message, origin: ORIGIN)

    result = @manager.cancel(prompt)

    assert_rejected result, 'NotAllowedError'
    assert_equal 'passkey-1', result.request_id
    assert_empty @store.saved
  end
end
