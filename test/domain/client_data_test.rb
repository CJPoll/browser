require 'minitest/autorun'
require 'json'
require 'digest'
require_relative '../../lib/domain/client_data'

class ClientDataTest < Minitest::Test
  CHALLENGE = 'Y2hhbGxlbmdl'.freeze
  ORIGIN = 'https://example.com'.freeze

  def test_describes_a_registration
    json = Domain::ClientData.json(type: Domain::ClientData::CREATE, challenge: CHALLENGE, origin: ORIGIN)

    assert_equal(
      { 'type' => 'webauthn.create', 'challenge' => CHALLENGE, 'origin' => ORIGIN, 'crossOrigin' => false },
      JSON.parse(json)
    )
  end

  def test_describes_an_authentication
    json = Domain::ClientData.json(type: Domain::ClientData::GET, challenge: CHALLENGE, origin: ORIGIN)

    assert_equal 'webauthn.get', JSON.parse(json)['type']
  end

  def test_passes_the_challenge_through_untouched
    # The site compares the challenge it sent with the one it gets back, so
    # the bytes must not be re-encoded on the way through.
    json = Domain::ClientData.json(type: Domain::ClientData::CREATE, challenge: 'abc-_', origin: ORIGIN)

    assert_equal 'abc-_', JSON.parse(json)['challenge']
  end

  def test_rejects_an_unknown_type
    assert_raises(ArgumentError) do
      Domain::ClientData.json(type: 'webauthn.other', challenge: CHALLENGE, origin: ORIGIN)
    end
  end

  def test_hashes_the_json_bytes_with_sha256
    json = Domain::ClientData.json(type: Domain::ClientData::GET, challenge: CHALLENGE, origin: ORIGIN)

    assert_equal Digest::SHA256.digest(json), Domain::ClientData.hash(json)
    assert_equal 32, Domain::ClientData.hash(json).bytesize
  end

  def test_the_same_inputs_produce_the_same_json
    first = Domain::ClientData.json(type: Domain::ClientData::GET, challenge: CHALLENGE, origin: ORIGIN)
    second = Domain::ClientData.json(type: Domain::ClientData::GET, challenge: CHALLENGE, origin: ORIGIN)

    assert_equal first, second
  end
end
