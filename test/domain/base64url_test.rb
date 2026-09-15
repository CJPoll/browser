require 'minitest/autorun'
require_relative '../../lib/domain/base64url'

class Base64UrlTest < Minitest::Test
  def test_encodes_without_padding
    assert_equal 'AQID', Domain::Base64Url.encode("\x01\x02\x03".b)
    assert_equal 'AQI', Domain::Base64Url.encode("\x01\x02".b)
  end

  def test_uses_the_url_safe_alphabet
    # 0xFB 0xFF is "+/8=" in standard base64.
    assert_equal '-_8', Domain::Base64Url.encode("\xFB\xFF".b)
  end

  def test_decodes_unpadded_text
    assert_equal "\x01\x02".b, Domain::Base64Url.decode('AQI')
  end

  def test_decodes_the_url_safe_alphabet
    assert_equal "\xFB\xFF".b, Domain::Base64Url.decode('-_8')
  end

  def test_round_trips_every_byte_value
    bytes = (0..255).to_a.pack('C*')

    assert_equal bytes, Domain::Base64Url.decode(Domain::Base64Url.encode(bytes))
  end

  def test_decoded_bytes_are_binary
    assert_equal Encoding::ASCII_8BIT, Domain::Base64Url.decode('AQI').encoding
  end

  def test_encodes_and_decodes_the_empty_string
    assert_equal '', Domain::Base64Url.encode('')
    assert_equal '', Domain::Base64Url.decode('')
  end

  def test_rejects_text_outside_the_alphabet
    assert_raises(ArgumentError) { Domain::Base64Url.decode('not base64!') }
  end

  def test_rejects_a_missing_value
    assert_raises(ArgumentError) { Domain::Base64Url.decode(nil) }
  end
end
