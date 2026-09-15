# frozen_string_literal: true

require 'openssl'

module Adapters
  # Makes and uses ES256 keys (ECDSA over P-256 with SHA-256), the one
  # algorithm every WebAuthn relying party accepts.
  #
  # An adapter rather than Domain because both operations draw randomness:
  # key generation obviously, and ECDSA signing for its per-signature nonce.
  # Everything deterministic about a key -- how it is laid out in
  # authenticator data -- stays in Domain.
  class Es256Signer
    CURVE = 'prime256v1'
    DIGEST = 'SHA256'
    UNCOMPRESSED_POINT_PREFIX = "\x04".b
    COORDINATE_BYTES = 32

    # A freshly made key: the private half as PKCS#8 PEM for the store, the
    # public half both as SubjectPublicKeyInfo DER (what the page's
    # `getPublicKey()` returns) and as raw coordinates (what the COSE key needs).
    KeyPair = Struct.new(:private_key_pem, :public_key_der, :x, :y, keyword_init: true)

    # @return [KeyPair]
    def generate
      key = OpenSSL::PKey::EC.generate(CURVE)
      point = key.public_key.to_octet_string(:uncompressed).b

      KeyPair.new(
        private_key_pem: key.private_to_pem,
        public_key_der: key.public_to_der,
        x: point[UNCOMPRESSED_POINT_PREFIX.bytesize, COORDINATE_BYTES],
        y: point[UNCOMPRESSED_POINT_PREFIX.bytesize + COORDINATE_BYTES, COORDINATE_BYTES]
      )
    end

    # @param private_key_pem [String] As returned by `generate`
    # @param data [String] The bytes to sign
    # @return [String] DER-encoded ECDSA signature
    # @raise [OpenSSL::PKey::PKeyError] If the PEM is not a usable key
    def sign(private_key_pem, data)
      OpenSSL::PKey.read(private_key_pem).sign(DIGEST, data)
    end
  end
end
