require 'minitest/autorun'
require 'openssl'
require_relative '../../lib/adapters/es256_signer'

# The signer is a thin wrapper over OpenSSL, so it is tested against the real
# thing: a key it makes must verify a signature it produces.
class AdaptersEs256SignerTest < Minitest::Test
  DATA = 'authenticator data followed by the client data hash'.b.freeze

  def setup
    @signer = Adapters::Es256Signer.new
  end

  # --- generate ---

  def test_generates_a_pkcs8_private_key
    key_pair = @signer.generate

    assert_match(/\A-----BEGIN PRIVATE KEY-----/, key_pair.private_key_pem)
    assert_equal 'prime256v1', OpenSSL::PKey.read(key_pair.private_key_pem).group.curve_name
  end

  def test_generates_a_public_key_in_der_form
    key_pair = @signer.generate
    public_key = OpenSSL::PKey.read(key_pair.public_key_der)

    assert_kind_of OpenSSL::PKey::EC, public_key
    refute public_key.private?
  end

  def test_exposes_the_public_point_as_two_32_byte_coordinates
    key_pair = @signer.generate

    assert_equal 32, key_pair.x.bytesize
    assert_equal 32, key_pair.y.bytesize
    assert_equal Encoding::ASCII_8BIT, key_pair.x.encoding
  end

  def test_the_coordinates_are_the_public_key_in_the_der
    key_pair = @signer.generate
    point = OpenSSL::PKey.read(key_pair.public_key_der).public_key.to_octet_string(:uncompressed)

    assert_equal "\x04".b + key_pair.x + key_pair.y, point
  end

  def test_every_generated_key_is_different
    refute_equal @signer.generate.private_key_pem, @signer.generate.private_key_pem
  end

  # --- sign ---

  def test_signs_data_so_the_public_key_verifies_it
    key_pair = @signer.generate

    signature = @signer.sign(key_pair.private_key_pem, DATA)

    assert OpenSSL::PKey.read(key_pair.public_key_der).verify('SHA256', signature, DATA)
  end

  def test_the_signature_is_der_encoded
    signature = @signer.sign(@signer.generate.private_key_pem, DATA)

    # A DER ECDSA signature is a SEQUENCE of two INTEGERs.
    sequence = OpenSSL::ASN1.decode(signature)
    assert_kind_of OpenSSL::ASN1::Sequence, sequence
    assert_equal 2, sequence.value.length
    sequence.value.each { |integer| assert_kind_of OpenSSL::ASN1::Integer, integer }
  end

  def test_a_signature_does_not_verify_against_other_data
    key_pair = @signer.generate

    signature = @signer.sign(key_pair.private_key_pem, DATA)

    refute OpenSSL::PKey.read(key_pair.public_key_der).verify('SHA256', signature, DATA + 'x')
  end

  def test_a_signature_does_not_verify_against_another_key
    key_pair = @signer.generate
    other = @signer.generate

    signature = @signer.sign(key_pair.private_key_pem, DATA)

    refute OpenSSL::PKey.read(other.public_key_der).verify('SHA256', signature, DATA)
  end

  def test_refuses_a_key_that_is_not_a_key
    assert_raises(OpenSSL::PKey::PKeyError) { @signer.sign('not a pem', DATA) }
  end
end
