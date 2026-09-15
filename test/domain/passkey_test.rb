require 'minitest/autorun'
require_relative '../../lib/domain/passkey'

class PasskeyTest < Minitest::Test
  CREATED_AT = Time.at(1_700_000_000).freeze
  PEM = "-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----\n".freeze

  def build(**overrides)
    Domain::Passkey.new(**{
      credential_id: 'Y3JlZC0x',
      rp_id: 'example.com',
      user_handle: 'dXNlci0x',
      user_name: 'cody@example.com',
      user_display_name: 'Cody',
      private_key_pem: PEM,
      created_at: CREATED_AT
    }.merge(overrides))
  end

  def test_exposes_its_attributes
    passkey = build

    assert_equal 'Y3JlZC0x', passkey.credential_id
    assert_equal 'example.com', passkey.rp_id
    assert_equal 'dXNlci0x', passkey.user_handle
    assert_equal 'cody@example.com', passkey.user_name
    assert_equal 'Cody', passkey.user_display_name
    assert_equal PEM, passkey.private_key_pem
    assert_equal CREATED_AT, passkey.created_at
  end

  def test_has_no_store_id_until_saved
    assert_nil build.store_id
    assert_equal 'op-item-1', build(store_id: 'op-item-1').store_id
  end

  def test_the_sign_count_is_always_zero
    # Synced passkeys report a constant counter; a counter that could not be
    # persisted atomically would trip the site's clone detection instead.
    assert_equal 0, build.sign_count
  end

  def test_the_user_label_prefers_the_display_name
    assert_equal 'Cody', build.user_label
  end

  def test_the_user_label_falls_back_to_the_account_name
    assert_equal 'cody@example.com', build(user_display_name: nil).user_label
    assert_equal 'cody@example.com', build(user_display_name: '').user_label
  end

  def test_the_user_label_falls_back_to_the_site_when_the_user_is_anonymous
    assert_equal 'example.com', build(user_display_name: nil, user_name: nil).user_label
  end

  def test_requires_the_identifying_attributes
    %i[credential_id rp_id user_handle private_key_pem created_at].each do |attribute|
      error = assert_raises(ArgumentError) { build(attribute => nil) }
      assert_match(/#{attribute}/, error.message)
    end
  end

  def test_is_frozen
    assert build.frozen?
  end

  # --- with ---

  def test_with_returns_a_copy_carrying_the_override
    original = build
    saved = original.with(store_id: 'op-item-1')

    assert_equal 'op-item-1', saved.store_id
    assert_nil original.store_id
    assert_equal original.credential_id, saved.credential_id
  end

  # --- Value semantics ---

  def test_passkeys_with_the_same_attributes_are_equal
    assert_equal build, build
    assert_equal build.hash, build.hash
  end

  def test_passkeys_differing_in_credential_id_are_not_equal
    refute_equal build, build(credential_id: 'other')
  end

  def test_a_passkey_is_not_equal_to_a_lookalike_hash
    refute_equal build, build.to_h
  end

  def test_to_h_exposes_every_attribute
    assert_equal(
      {
        credential_id: 'Y3JlZC0x', rp_id: 'example.com', user_handle: 'dXNlci0x',
        user_name: 'cody@example.com', user_display_name: 'Cody', private_key_pem: PEM,
        sign_count: 0, created_at: CREATED_AT, store_id: nil
      },
      build.to_h
    )
  end
end
