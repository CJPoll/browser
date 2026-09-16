require 'minitest/autorun'
require 'digest'
require_relative '../../lib/domain/authenticator_data'

class AuthenticatorDataTest < Minitest::Test
  RP_ID = 'example.com'.freeze
  CREDENTIAL_ID = "\x01\x02\x03\x04".b.freeze
  COSE_KEY = "\xA5\x01\x02".b.freeze

  def build(**overrides)
    Domain::AuthenticatorData.build(**{ rp_id: RP_ID, sign_count: 0, user_verified: false, backed_up: false }.merge(overrides))
  end

  def flags(data)
    data.getbyte(32)
  end

  def test_starts_with_the_hash_of_the_rp_id
    assert_equal Digest::SHA256.digest(RP_ID), build[0, 32]
  end

  def test_is_37_bytes_without_a_credential
    assert_equal 37, build.bytesize
  end

  def test_always_claims_user_presence
    assert_equal 0x01, flags(build)
  end

  def test_flags_user_verification
    assert_equal 0x01 | 0x04, flags(build(user_verified: true))
  end

  def test_a_backed_up_key_is_both_eligible_and_backed_up
    assert_equal 0x01 | 0x08 | 0x10, flags(build(backed_up: true))
  end

  def test_flags_an_attested_credential
    data = build(credential: { id: CREDENTIAL_ID, cose_public_key: COSE_KEY })

    assert_equal 0x01 | 0x40, flags(data)
  end

  def test_writes_the_sign_count_big_endian
    assert_equal "\x00\x00\x01\x02".b, build(sign_count: 258)[33, 4]
  end

  def test_appends_the_attested_credential_data
    data = build(credential: { id: CREDENTIAL_ID, cose_public_key: COSE_KEY })
    attested = data[37..]

    assert_equal ("\x00" * 16).b, attested[0, 16], 'AAGUID is all zeros'
    assert_equal "\x00\x04".b, attested[16, 2], 'credential id length, big endian'
    assert_equal CREDENTIAL_ID, attested[18, 4]
    assert_equal COSE_KEY, attested[22..]
  end

  def test_is_binary
    assert_equal Encoding::ASCII_8BIT, build.encoding
    assert_equal Encoding::ASCII_8BIT, build(credential: { id: CREDENTIAL_ID, cose_public_key: COSE_KEY }).encoding
  end

  def test_requires_an_rp_id
    assert_raises(ArgumentError) { build(rp_id: nil) }
    assert_raises(ArgumentError) { build(rp_id: '') }
  end

  def test_requires_a_credential_id_when_attesting
    assert_raises(ArgumentError) { build(credential: { id: '', cose_public_key: COSE_KEY }) }
  end

  def test_requires_a_public_key_when_attesting
    assert_raises(ArgumentError) { build(credential: { id: CREDENTIAL_ID, cose_public_key: '' }) }
  end

  def test_rejects_a_credential_id_too_long_for_its_length_field
    too_long = ("\x00" * 1024).b

    assert_raises(ArgumentError) { build(credential: { id: too_long, cose_public_key: COSE_KEY }) }
  end
end
