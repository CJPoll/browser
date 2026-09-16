# frozen_string_literal: true

module Domain
  # The byte encoding WebAuthn uses wherever binary data crosses into JSON:
  # base64 with the URL-safe alphabet and no padding.
  #
  # Every challenge, credential ID and user handle crosses the JavaScript
  # boundary in this form, so it is spelled out once here rather than as
  # `pack`/`tr` chains at each call site.
  module Base64Url
    # @param bytes [String] Binary data
    # @return [String] Unpadded base64url text
    def self.encode(bytes)
      [bytes].pack('m0').tr('+/', '-_').delete('=')
    end

    # @param text [String] Unpadded (or padded) base64url text
    # @return [String] The decoded bytes, binary-encoded
    # @raise [ArgumentError] If the text is not base64url
    def self.decode(text)
      raise ArgumentError, 'base64url text is required' unless text.is_a?(String)

      padded = text.tr('-_', '+/')
      padded += '=' * ((4 - (padded.length % 4)) % 4)
      padded.unpack1('m0')
    end
  end
end
