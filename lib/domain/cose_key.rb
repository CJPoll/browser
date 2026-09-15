# frozen_string_literal: true

require 'cbor'

module Domain
  # A public key in the COSE_Key form WebAuthn embeds in authenticator data.
  #
  # Only ES256 (ECDSA over P-256 with SHA-256) is produced, because it is the
  # one algorithm every relying party accepts and the one the signer makes.
  #
  # The `cbor` gem is a pure transform (bytes in, bytes out), which is what
  # allows it in Domain -- see "a third-party library is Domain if the
  # library is a pure transform" in lib/domain/CLAUDE.md.
  module CoseKey
    KEY_TYPE = 1
    ALGORITHM = 3
    CURVE = -1
    X_COORDINATE = -2
    Y_COORDINATE = -3

    EC2 = 2
    ES256 = -7
    P256 = 1
    COORDINATE_BYTES = 32

    # @param x [String] The 32-byte X coordinate
    # @param y [String] The 32-byte Y coordinate
    # @return [String] CBOR, in CTAP2 canonical key order
    def self.es256(x:, y:)
      x = coordinate(x, 'x')
      y = coordinate(y, 'y')

      # Insertion order is encoding order, and this order is canonical:
      # keys 1 and 3 encode in one byte, then -1, -2, -3 in ascending order.
      CBOR.encode(KEY_TYPE => EC2, ALGORITHM => ES256, CURVE => P256, X_COORDINATE => x, Y_COORDINATE => y)
    end

    def self.coordinate(value, name)
      bytes = value.to_s.b
      unless bytes.bytesize == COORDINATE_BYTES
        raise ArgumentError, "#{name} coordinate must be #{COORDINATE_BYTES} bytes, got #{bytes.bytesize}"
      end

      bytes
    end
    private_class_method :coordinate
  end
end
