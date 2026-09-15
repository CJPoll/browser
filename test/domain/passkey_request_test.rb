require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/passkey_request'

class PasskeyRequestTest < Minitest::Test
  CHALLENGE = 'Y2hhbGxlbmdl'.freeze
  USER_ID = 'dXNlci0x'.freeze

  def create_options(**overrides)
    {
      'rp' => { 'id' => 'example.com', 'name' => 'Example' },
      'user' => { 'id' => USER_ID, 'name' => 'cody@example.com', 'displayName' => 'Cody' },
      'challenge' => CHALLENGE,
      'pubKeyCredParams' => [{ 'type' => 'public-key', 'alg' => -7 }, { 'type' => 'public-key', 'alg' => -257 }],
      'excludeCredentials' => [{ 'type' => 'public-key', 'id' => 'b2xk' }],
      'authenticatorSelection' => { 'userVerification' => 'required', 'residentKey' => 'required' },
      'attestation' => 'none'
    }.merge(overrides)
  end

  def get_options(**overrides)
    {
      'rpId' => 'example.com',
      'challenge' => CHALLENGE,
      'allowCredentials' => [{ 'type' => 'public-key', 'id' => 'Y3JlZC0x' }, { 'type' => 'public-key', 'id' => 'Y3JlZC0y' }],
      'userVerification' => 'discouraged'
    }.merge(overrides)
  end

  # Named to stay clear of Minitest's own `message` helper.
  def request_json(op:, options:, id: 'passkey-1', mediation: 'optional')
    JSON.generate({ 'id' => id, 'op' => op, 'mediation' => mediation, 'options' => options })
  end

  def parse_create(options = create_options, **overrides)
    Domain::PasskeyRequest.parse(request_json(op: 'create', options: options, **overrides))
  end

  def parse_get(options = get_options, **overrides)
    Domain::PasskeyRequest.parse(request_json(op: 'get', options: options, **overrides))
  end

  # --- Creation requests ---

  def test_parses_a_creation_request
    request = parse_create

    assert_equal 'passkey-1', request.request_id
    assert_equal :create, request.operation
    assert request.create?
    refute request.get?
    assert_equal CHALLENGE, request.challenge
    assert_equal 'example.com', request.rp_id
    assert_equal 'Example', request.rp_name
    assert_equal USER_ID, request.user_id
    assert_equal 'cody@example.com', request.user_name
    assert_equal 'Cody', request.user_display_name
    assert_equal [-7, -257], request.algorithms
    assert_equal ['b2xk'], request.exclude_credential_ids
    assert_equal 'required', request.user_verification
  end

  def test_a_creation_request_may_leave_the_rp_id_to_the_origin
    request = parse_create(create_options('rp' => { 'name' => 'Example' }))

    assert_nil request.rp_id
  end

  def test_only_public_key_parameters_count_as_algorithms
    options = create_options('pubKeyCredParams' => [{ 'type' => 'other', 'alg' => -7 }, { 'type' => 'public-key', 'alg' => -8 }])

    assert_equal [-8], parse_create(options).algorithms
  end

  def test_supports_es256_when_the_site_lists_it
    assert parse_create.supports_es256?
  end

  def test_does_not_support_a_site_that_only_accepts_other_algorithms
    options = create_options('pubKeyCredParams' => [{ 'type' => 'public-key', 'alg' => -257 }])

    refute parse_create(options).supports_es256?
  end

  def test_an_empty_algorithm_list_means_the_defaults_which_include_es256
    assert parse_create(create_options('pubKeyCredParams' => [])).supports_es256?
  end

  def test_user_verification_defaults_to_preferred
    options = create_options('authenticatorSelection' => {})

    assert_equal 'preferred', parse_create(options).user_verification
  end

  def test_the_user_label_prefers_the_display_name
    assert_equal 'Cody', parse_create.user_label
  end

  def test_the_user_label_falls_back_to_the_account_name
    options = create_options('user' => { 'id' => USER_ID, 'name' => 'cody@example.com' })

    assert_equal 'cody@example.com', parse_create(options).user_label
  end

  def test_a_blank_display_name_does_not_count
    options = create_options('user' => { 'id' => USER_ID, 'name' => 'cody@example.com', 'displayName' => '  ' })

    assert_equal 'cody@example.com', parse_create(options).user_label
  end

  # --- Assertion requests ---

  def test_parses_an_assertion_request
    request = parse_get

    assert_equal :get, request.operation
    assert request.get?
    assert_equal 'example.com', request.rp_id
    assert_equal %w[Y3JlZC0x Y3JlZC0y], request.allow_credential_ids
    assert_equal 'discouraged', request.user_verification
    assert_nil request.user_id
    assert_empty request.exclude_credential_ids
  end

  def test_an_assertion_request_may_allow_any_credential
    request = parse_get(get_options('allowCredentials' => nil))

    assert_empty request.allow_credential_ids
  end

  def test_an_assertion_request_needs_no_user
    assert_nil parse_get.user_label
  end

  # --- Mediation ---

  def test_recognises_a_conditional_request
    assert parse_get(mediation: 'conditional').conditional?
    refute parse_get.conditional?
  end

  def test_mediation_defaults_to_optional
    request = Domain::PasskeyRequest.parse(JSON.generate({ 'id' => 'x', 'op' => 'get', 'options' => get_options }))

    assert_equal 'optional', request.mediation
  end

  # --- Malformed input ---

  def test_rejects_text_that_is_not_json
    assert_malformed('not json')
  end

  def test_rejects_json_that_is_not_an_object
    assert_malformed('[1, 2]')
    assert_malformed('null')
  end

  def test_rejects_a_missing_request_id
    assert_malformed(request_json(op: 'create', options: create_options, id: nil))
    assert_malformed(request_json(op: 'create', options: create_options, id: ''))
  end

  def test_rejects_an_unknown_operation
    assert_malformed(request_json(op: 'store', options: get_options))
  end

  def test_rejects_missing_options
    assert_malformed(JSON.generate({ 'id' => 'x', 'op' => 'get' }))
  end

  def test_rejects_a_missing_challenge
    assert_malformed(request_json(op: 'get', options: get_options('challenge' => nil)))
    assert_malformed(request_json(op: 'get', options: get_options('challenge' => '')))
  end

  def test_a_creation_request_must_name_the_user
    assert_malformed(request_json(op: 'create', options: create_options('user' => nil)))
    assert_malformed(request_json(op: 'create', options: create_options('user' => { 'name' => 'cody' })))
    assert_malformed(request_json(op: 'create', options: create_options('user' => { 'id' => USER_ID })))
  end

  def test_malformed_is_an_argument_error
    assert_kind_of ArgumentError, Domain::PasskeyRequest::Malformed.new
  end

  # --- Value semantics ---

  def test_requests_parsed_from_the_same_message_are_equal
    assert_equal parse_create, parse_create
    assert_equal parse_create.hash, parse_create.hash
  end

  def test_requests_differing_in_operation_are_not_equal
    refute_equal parse_create, parse_get
  end

  def test_requests_are_frozen
    assert parse_create.frozen?
  end

  private

  def assert_malformed(text)
    assert_raises(Domain::PasskeyRequest::Malformed) { Domain::PasskeyRequest.parse(text) }
  end
end
