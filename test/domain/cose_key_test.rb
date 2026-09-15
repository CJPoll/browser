require 'minitest/autorun'
require 'cbor'
require_relative '../../lib/domain/cose_key'

class CoseKeyTest < Minitest::Test
  X = ("\x11" * 32).b.freeze
  Y = ("\x22" * 32).b.freeze

  def test_encodes_an_ec2_p256_key_for_es256
    decoded = CBOR.decode(Domain::CoseKey.es256(x: X, y: Y))

    assert_equal({ 1 => 2, 3 => -7, -1 => 1, -2 => X, -3 => Y }, decoded)
  end

  def test_coordinates_are_byte_strings
    decoded = CBOR.decode(Domain::CoseKey.es256(x: X, y: Y))

    assert_equal Encoding::ASCII_8BIT, decoded[-2].encoding
    assert_equal Encoding::ASCII_8BIT, decoded[-3].encoding
  end

  def test_writes_the_map_in_canonical_key_order
    # CTAP2 canonical CBOR: shorter-encoded keys first, so 1, 3, -1, -2, -3.
    # A5 = map(5); 01 02 = 1: 2; 03 26 = 3: -7; 20 01 = -1: 1; 21 58 20 = -2: bytes(32)
    expected_prefix = "\xA5\x01\x02\x03\x26\x20\x01\x21\x58\x20".b

    assert_equal expected_prefix, Domain::CoseKey.es256(x: X, y: Y)[0, expected_prefix.bytesize]
  end

  def test_rejects_a_coordinate_that_is_not_32_bytes
    assert_raises(ArgumentError) { Domain::CoseKey.es256(x: X[0, 31], y: Y) }
    assert_raises(ArgumentError) { Domain::CoseKey.es256(x: X, y: Y + "\x00".b) }
  end

  def test_accepts_coordinates_in_any_string_encoding
    # The signer may hand over coordinates tagged as UTF-8; only the bytes matter.
    utf8_x = X.dup.force_encoding(Encoding::UTF_8)

    assert_equal X, CBOR.decode(Domain::CoseKey.es256(x: utf8_x, y: Y))[-2]
  end
end
