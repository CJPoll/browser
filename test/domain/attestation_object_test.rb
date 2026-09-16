require 'minitest/autorun'
require 'cbor'
require_relative '../../lib/domain/attestation_object'

class AttestationObjectTest < Minitest::Test
  AUTH_DATA = ("\xAB" * 37).b.freeze

  def test_declares_no_attestation
    decoded = CBOR.decode(Domain::AttestationObject.none(authenticator_data: AUTH_DATA))

    assert_equal({ 'fmt' => 'none', 'attStmt' => {}, 'authData' => AUTH_DATA }, decoded)
  end

  def test_the_authenticator_data_is_a_byte_string
    decoded = CBOR.decode(Domain::AttestationObject.none(authenticator_data: AUTH_DATA))

    assert_equal Encoding::ASCII_8BIT, decoded['authData'].encoding
  end

  def test_the_format_is_a_text_string
    decoded = CBOR.decode(Domain::AttestationObject.none(authenticator_data: AUTH_DATA))

    assert_equal Encoding::UTF_8, decoded['fmt'].encoding
  end

  def test_writes_the_map_in_canonical_key_order
    # A3 = map(3); 63 "fmt"; 64 "none"; 67 "attStmt"; A0 = {}; 68 "authData"; 58 25 = bytes(37)
    expected_prefix = "\xA3\x63fmt\x64none\x67attStmt\xA0\x68authData\x58\x25".b

    assert_equal expected_prefix, Domain::AttestationObject.none(authenticator_data: AUTH_DATA)[0, expected_prefix.bytesize]
  end

  def test_requires_authenticator_data
    assert_raises(ArgumentError) { Domain::AttestationObject.none(authenticator_data: '') }
    assert_raises(ArgumentError) { Domain::AttestationObject.none(authenticator_data: nil) }
  end
end
