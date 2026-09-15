require 'minitest/autorun'
require 'json'
require 'cbor'
require 'digest'
require 'openssl'
require_relative '../../lib/managers/passkey_manager'
require_relative '../../lib/adapters/es256_signer'
require_relative '../../lib/domain/base64url'
require_relative '../support/test_clock'

# Integration test for the passkey ceremonies without mocks of the crypto:
# Domain <-> PasskeyManager <-> Es256Signer, with an in-memory store standing
# in for 1Password (the real store shells out to `op`, which needs a signed-in
# vault -- see the manual test plan in ai-artifacts/specs/passkeys.md).
#
# The test plays the relying party: it decodes what a site would receive and
# verifies the sign-in signature against the public key from registration,
# which is the whole point of the exchange.
class PasskeyFlowTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze
  ORIGIN = 'https://accounts.example.com'.freeze
  RP_ID = 'example.com'.freeze

  class MemoryStore
    def initialize
      @passkeys = []
    end

    def save(passkey)
      saved = passkey.with(store_id: "item-#{@passkeys.length + 1}")
      @passkeys << saved
      saved
    end

    def find_for_rp(rp_id)
      @passkeys.select { |passkey| passkey.rp_id == rp_id }
    end
  end

  def setup
    @manager = Managers::PasskeyManager.new(store: MemoryStore.new, signer: Adapters::Es256Signer.new, clock: TestClock.new(NOW))
  end

  def decode(text)
    Domain::Base64Url.decode(text)
  end

  def registration_challenge
    Domain::Base64Url.encode(OpenSSL::Random.random_bytes(32))
  end

  def create_message(challenge)
    JSON.generate(
      'id' => 'passkey-1', 'op' => 'create',
      'options' => {
        'rp' => { 'id' => RP_ID, 'name' => 'Example' },
        'user' => { 'id' => 'dXNlci0x', 'name' => 'cody@example.com', 'displayName' => 'Cody' },
        'challenge' => challenge,
        'pubKeyCredParams' => [{ 'type' => 'public-key', 'alg' => -7 }],
        'authenticatorSelection' => { 'userVerification' => 'required', 'residentKey' => 'required' }
      }
    )
  end

  def get_message(challenge, credential_id)
    JSON.generate(
      'id' => 'passkey-2', 'op' => 'get',
      'options' => { 'rpId' => RP_ID, 'challenge' => challenge, 'allowCredentials' => [{ 'type' => 'public-key', 'id' => credential_id }] }
    )
  end

  # What a relying party would pull out of the attestation object.
  def public_key_from(attestation_object)
    auth_data = CBOR.decode(attestation_object)['authData']
    id_length = auth_data[53, 2].unpack1('n')
    cose_key = CBOR.decode(auth_data[55 + id_length..])
    point = "\x04".b + cose_key[-2] + cose_key[-3]
    group = OpenSSL::PKey::EC::Group.new('prime256v1')
    OpenSSL::PKey::EC.new(OpenSSL::ASN1::Sequence.new([
      OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::ObjectId.new('id-ecPublicKey'), OpenSSL::ASN1::ObjectId.new('prime256v1')]),
      OpenSSL::ASN1::BitString.new(point)
    ]).to_der).tap { |key| assert_equal group.curve_name, key.group.curve_name }
  end

  def test_happy_path_registering_then_signing_in_verifies_like_a_relying_party
    # 1. The site asks to create a passkey; the browser asks the user
    challenge = registration_challenge
    prompt = @manager.prepare(create_message(challenge), origin: ORIGIN)
    assert_kind_of Domain::PasskeyPrompt, prompt
    assert_equal RP_ID, prompt.rp_id

    # 2. The user agrees; the site receives an attestation it can check
    registration = @manager.register(prompt)
    assert registration.resolved?
    client_data = JSON.parse(decode(registration.credential['clientDataJSON']))
    assert_equal 'webauthn.create', client_data['type']
    assert_equal challenge, client_data['challenge']
    assert_equal ORIGIN, client_data['origin']

    attestation_object = decode(registration.credential['attestationObject'])
    auth_data = CBOR.decode(attestation_object)['authData']
    assert_equal Digest::SHA256.digest(RP_ID), auth_data[0, 32]
    assert_equal 0x45, auth_data.getbyte(32) & 0x45, 'user present, user verified, attested credential'
    credential_id = registration.credential['id']
    assert_equal decode(credential_id), auth_data[55, 32]

    public_key = public_key_from(attestation_object)
    assert_equal decode(registration.credential['publicKey']), public_key.public_to_der, 'getPublicKey() matches the attested key'

    # 3. The site later asks for a signature over a fresh challenge with that credential
    sign_in_challenge = registration_challenge
    prompt = @manager.prepare(get_message(sign_in_challenge, credential_id), origin: ORIGIN)
    assert_kind_of Domain::PasskeyPrompt, prompt
    assert_equal [credential_id], prompt.candidates.map(&:credential_id)

    # 4. The user agrees; the signature verifies against the registered key
    assertion = @manager.authenticate(prompt, prompt.candidates.first)
    assert assertion.resolved?
    assert_equal credential_id, assertion.credential['id']
    assert_equal 'dXNlci0x', assertion.credential['userHandle']

    client_data_json = decode(assertion.credential['clientDataJSON'])
    assert_equal sign_in_challenge, JSON.parse(client_data_json)['challenge']
    assert_equal 'webauthn.get', JSON.parse(client_data_json)['type']

    authenticator_data = decode(assertion.credential['authenticatorData'])
    assert_equal Digest::SHA256.digest(RP_ID), authenticator_data[0, 32]
    signed = authenticator_data + Digest::SHA256.digest(client_data_json)
    assert public_key.verify('SHA256', decode(assertion.credential['signature']), signed)
  end

  def test_a_signature_for_one_challenge_does_not_verify_for_another
    prompt = @manager.prepare(create_message(registration_challenge), origin: ORIGIN)
    registration = @manager.register(prompt)
    public_key = public_key_from(decode(registration.credential['attestationObject']))

    prompt = @manager.prepare(get_message(registration_challenge, registration.credential['id']), origin: ORIGIN)
    assertion = @manager.authenticate(prompt, prompt.candidates.first)

    authenticator_data = decode(assertion.credential['authenticatorData'])
    other_client_data = JSON.generate('type' => 'webauthn.get', 'challenge' => registration_challenge, 'origin' => ORIGIN, 'crossOrigin' => false)
    refute public_key.verify('SHA256', decode(assertion.credential['signature']), authenticator_data + Digest::SHA256.digest(other_client_data))
  end

  def test_a_passkey_made_for_one_site_is_not_offered_to_another
    prompt = @manager.prepare(create_message(registration_challenge), origin: ORIGIN)
    registration = @manager.register(prompt)

    message = JSON.generate('id' => 'passkey-3', 'op' => 'get', 'options' => { 'challenge' => registration_challenge })
    result = @manager.prepare(message, origin: 'https://other.example')

    assert result.rejected?, "expected no passkey for other.example, got #{result.inspect}"
    assert_equal 'NotAllowedError', result.error_name
    refute_nil registration.credential['id']
  end
end
