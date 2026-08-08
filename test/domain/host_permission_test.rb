require 'minitest/autorun'
require_relative '../../lib/domain/host_permission'

class HostPermissionTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def build_permission(**overrides)
    Domain::HostPermission.new(
      **{ host: 'example.com', granted_at: GRANTED_AT }.merge(overrides)
    )
  end

  # --- Construction ---

  def test_exposes_host_and_grant_time
    permission = build_permission

    assert_equal 'example.com', permission.host
    assert_equal GRANTED_AT, permission.granted_at
  end

  def test_id_is_nil_until_persisted
    assert_nil build_permission.id
  end

  def test_permission_type_is_nil_for_permissions_without_subtypes
    assert_nil build_permission.permission_type
  end

  def test_permission_type_is_normalized_to_a_symbol
    assert_equal :audio_video, build_permission(permission_type: 'audio_video').permission_type
    assert_equal :audio, build_permission(permission_type: :audio).permission_type
  end

  def test_requires_a_host
    assert_raises(ArgumentError) { build_permission(host: nil) }
    assert_raises(ArgumentError) { build_permission(host: '') }
  end

  # A default would be a clock read, which Domain must never do.
  def test_requires_an_injected_grant_time
    assert_raises(ArgumentError) { build_permission(granted_at: nil) }
    assert_raises(ArgumentError) { Domain::HostPermission.new(host: 'example.com') }
  end

  def test_is_immutable
    assert build_permission.frozen?
  end

  # --- with_id ---

  def test_with_id_returns_a_copy_carrying_the_id
    permission = build_permission(permission_type: :video)

    stored = permission.with_id(42)

    assert_equal 42, stored.id
    assert_equal 'example.com', stored.host
    assert_equal :video, stored.permission_type
    assert_equal GRANTED_AT, stored.granted_at
  end

  def test_with_id_does_not_mutate_the_original
    permission = build_permission

    permission.with_id(42)

    assert_nil permission.id
  end

  # --- Value semantics ---

  def test_equal_when_every_attribute_matches
    assert_equal build_permission, build_permission
    assert_equal build_permission.hash, build_permission.hash
  end

  def test_not_equal_when_an_attribute_differs
    refute_equal build_permission, build_permission(host: 'other.com')
    refute_equal build_permission, build_permission(permission_type: :audio)
    refute_equal build_permission, build_permission(granted_at: Time.at(1))
    refute_equal build_permission, build_permission.with_id(1)
  end

  def test_not_equal_to_a_lookalike_hash
    refute_equal build_permission, build_permission.to_h
  end

  def test_usable_as_a_hash_key
    set = { build_permission => :present }

    assert_equal :present, set[build_permission]
  end

  # --- to_h ---

  def test_to_h_exposes_every_attribute
    expected = { id: 7, host: 'example.com', permission_type: :audio, granted_at: GRANTED_AT }

    assert_equal expected, build_permission(permission_type: :audio).with_id(7).to_h
  end
end
