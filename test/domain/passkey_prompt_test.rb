require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/passkey_prompt'
require_relative '../../lib/domain/passkey_request'
require_relative '../../lib/domain/passkey'

class PasskeyPromptTest < Minitest::Test
  ORIGIN = 'https://accounts.example.com'.freeze
  CREATED_AT = Time.at(1_700_000_000).freeze

  def create_request(display_name: 'Cody')
    Domain::PasskeyRequest.parse(JSON.generate(
      'id' => 'passkey-1', 'op' => 'create',
      'options' => {
        'rp' => { 'id' => 'example.com' },
        'user' => { 'id' => 'dXNlcg', 'name' => 'cody@example.com', 'displayName' => display_name },
        'challenge' => 'Y2hhbGxlbmdl'
      }
    ))
  end

  def get_request
    Domain::PasskeyRequest.parse(JSON.generate(
      'id' => 'passkey-2', 'op' => 'get',
      'options' => { 'rpId' => 'example.com', 'challenge' => 'Y2hhbGxlbmdl' }
    ))
  end

  def passkey(name)
    Domain::Passkey.new(credential_id: "id-#{name}", rp_id: 'example.com', user_handle: 'dXNlcg',
                        user_name: name, private_key_pem: 'pem', created_at: CREATED_AT)
  end

  def create_prompt
    Domain::PasskeyPrompt.new(request: create_request, origin: ORIGIN, rp_id: 'example.com')
  end

  def get_prompt(candidates)
    Domain::PasskeyPrompt.new(request: get_request, origin: ORIGIN, rp_id: 'example.com', candidates: candidates)
  end

  def test_a_creation_prompt_names_the_site_and_the_account
    prompt = create_prompt

    assert prompt.create?
    refute prompt.get?
    assert_equal 'passkey-1', prompt.request_id
    assert_equal 'example.com wants to create a passkey for Cody', prompt.message
  end

  def test_a_creation_prompt_falls_back_to_the_account_name
    prompt = Domain::PasskeyPrompt.new(request: create_request(display_name: nil), origin: ORIGIN, rp_id: 'example.com')

    assert_equal 'example.com wants to create a passkey for cody@example.com', prompt.message
  end

  def test_a_creation_prompt_offers_no_candidates
    assert_empty create_prompt.candidates
    refute create_prompt.choice_needed?
  end

  def test_a_sign_in_prompt_with_one_passkey_names_it
    prompt = get_prompt([passkey('cody@example.com')])

    assert prompt.get?
    assert_equal 'Sign in to example.com with your passkey for cody@example.com', prompt.message
    refute prompt.choice_needed?
  end

  def test_a_sign_in_prompt_with_several_passkeys_asks_which
    prompt = get_prompt([passkey('cody@example.com'), passkey('work@example.com')])

    assert_equal 'Sign in to example.com -- choose a passkey', prompt.message
    assert prompt.choice_needed?
    assert_equal ['cody@example.com', 'work@example.com'], prompt.candidate_labels
  end

  def test_candidates_are_frozen
    assert get_prompt([passkey('a')]).candidates.frozen?
  end

  def test_requires_a_request_an_origin_and_an_rp_id
    assert_raises(ArgumentError) { Domain::PasskeyPrompt.new(request: nil, origin: ORIGIN, rp_id: 'example.com') }
    assert_raises(ArgumentError) { Domain::PasskeyPrompt.new(request: create_request, origin: nil, rp_id: 'example.com') }
    assert_raises(ArgumentError) { Domain::PasskeyPrompt.new(request: create_request, origin: ORIGIN, rp_id: nil) }
  end

  # --- Value semantics ---

  def test_prompts_with_the_same_attributes_are_equal
    assert_equal create_prompt, create_prompt
    assert_equal create_prompt.hash, create_prompt.hash
  end

  def test_prompts_with_different_candidates_are_not_equal
    refute_equal get_prompt([passkey('a')]), get_prompt([passkey('b')])
  end

  def test_to_h_exposes_every_attribute
    assert_equal(
      { request: create_request, origin: ORIGIN, rp_id: 'example.com', candidates: [] },
      create_prompt.to_h
    )
  end
end
