require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/passkey_response'
require_relative '../../lib/domain/base64url'

class PasskeyResponseTest < Minitest::Test
  CLIENT_DATA = '{"type":"webauthn.get"}'.freeze
  AUTH_DATA = "\x01\x02".b.freeze
  ATTESTATION = "\xA3\x63".b.freeze
  SIGNATURE = "\x30\x44".b.freeze
  PUBLIC_KEY = "\x30\x59".b.freeze

  def registered
    Domain::PasskeyResponse.registered(
      request_id: 'passkey-1', credential_id: 'Y3JlZA',
      client_data_json: CLIENT_DATA, attestation_object: ATTESTATION,
      authenticator_data: AUTH_DATA, public_key_der: PUBLIC_KEY
    )
  end

  def asserted
    Domain::PasskeyResponse.asserted(
      request_id: 'passkey-2', credential_id: 'Y3JlZA',
      client_data_json: CLIENT_DATA, authenticator_data: AUTH_DATA,
      signature: SIGNATURE, user_handle: 'dXNlcg'
    )
  end

  def rejected
    Domain::PasskeyResponse.rejected(request_id: 'passkey-3', name: Domain::PasskeyResponse::NOT_ALLOWED, message: 'The user declined')
  end

  def b64(bytes)
    Domain::Base64Url.encode(bytes)
  end

  # --- Registration ---

  def test_a_registration_carries_the_attestation_for_the_page
    response = registered

    assert response.resolved?
    refute response.rejected?
    assert_equal(
      {
        'id' => 'passkey-1', 'ok' => true,
        'credential' => {
          'id' => 'Y3JlZA',
          'clientDataJSON' => b64(CLIENT_DATA),
          'attestationObject' => b64(ATTESTATION),
          'authenticatorData' => b64(AUTH_DATA),
          'publicKey' => b64(PUBLIC_KEY),
          'publicKeyAlgorithm' => -7,
          'transports' => ['internal']
        }
      },
      response.to_h
    )
  end

  # --- Assertion ---

  def test_an_assertion_carries_the_signature_for_the_page
    response = asserted

    assert response.resolved?
    assert_equal(
      {
        'id' => 'passkey-2', 'ok' => true,
        'credential' => {
          'id' => 'Y3JlZA',
          'clientDataJSON' => b64(CLIENT_DATA),
          'authenticatorData' => b64(AUTH_DATA),
          'signature' => b64(SIGNATURE),
          'userHandle' => 'dXNlcg'
        }
      },
      response.to_h
    )
  end

  # --- Rejection ---

  def test_a_rejection_names_the_dom_exception_for_the_page
    response = rejected

    assert response.rejected?
    refute response.resolved?
    assert_equal 'NotAllowedError', response.error_name
    assert_equal 'The user declined', response.error_message
    assert_equal(
      { 'id' => 'passkey-3', 'ok' => false, 'error' => { 'name' => 'NotAllowedError', 'message' => 'The user declined' } },
      response.to_h
    )
  end

  def test_the_error_names_are_the_dom_exception_names_webauthn_uses
    assert_equal 'NotAllowedError', Domain::PasskeyResponse::NOT_ALLOWED
    assert_equal 'SecurityError', Domain::PasskeyResponse::SECURITY
    assert_equal 'NotSupportedError', Domain::PasskeyResponse::NOT_SUPPORTED
    assert_equal 'InvalidStateError', Domain::PasskeyResponse::INVALID_STATE
    assert_equal 'TypeError', Domain::PasskeyResponse::TYPE_ERROR
  end

  def test_requires_a_request_id
    assert_raises(ArgumentError) { Domain::PasskeyResponse.rejected(request_id: nil, name: 'NotAllowedError', message: 'x') }
  end

  def test_a_rejection_requires_a_name
    assert_raises(ArgumentError) { Domain::PasskeyResponse.rejected(request_id: 'x', name: nil, message: 'x') }
  end

  # --- Wire format ---

  def test_to_json_is_the_wire_form_of_to_h
    assert_equal rejected.to_h, JSON.parse(rejected.to_json)
    assert_equal registered.to_h, JSON.parse(registered.to_json)
  end

  # --- Value semantics ---

  def test_responses_with_the_same_attributes_are_equal
    assert_equal rejected, rejected
    assert_equal rejected.hash, rejected.hash
  end

  def test_responses_differing_in_outcome_are_not_equal
    refute_equal registered, asserted
    refute_equal asserted, rejected
  end
end
