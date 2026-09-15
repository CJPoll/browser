# frozen_string_literal: true

require 'uri'

module Domain
  # The web origin of a page -- scheme, host and non-default port -- and
  # whether it is one WebAuthn may be used from.
  #
  # `Domain::UrlHost` answers with a bare host because the permission stores
  # key on hosts. Passkeys are bound to the full origin (a passkey created on
  # `https://example.com` must not be usable from `http://example.com`), so
  # this module exists alongside it rather than extending it.
  module WebOrigin
    HTTP_SCHEMES = %w[http https].freeze
    DEFAULT_PORTS = { 'http' => 80, 'https' => 443 }.freeze
    SECURE_SCHEME = 'https'
    LOCAL_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze
    LOCAL_SUFFIX = '.localhost'

    # @param url [String, nil] Page URL
    # @return [String, nil] The origin, or nil for anything that is not an
    #   http(s) URL with a host
    def self.from_url(url)
      uri = parse(url)
      return nil unless uri

      scheme = uri.scheme.downcase
      port = uri.port.nil? || uri.port == DEFAULT_PORTS[scheme] ? '' : ":#{uri.port}"
      "#{scheme}://#{uri.host.downcase}#{port}"
    end

    # @param origin [String, nil] An origin as returned by `from_url`
    # @return [String, nil] Its host
    def self.host(origin)
      parse(origin)&.host&.downcase
    end

    # Whether WebAuthn may be used from this origin: HTTPS, or plain HTTP on
    # the local machine for development.
    #
    # @param origin [String, nil] An origin as returned by `from_url`
    # @return [Boolean]
    def self.secure?(origin)
      uri = parse(origin)
      return false unless uri
      return true if uri.scheme.downcase == SECURE_SCHEME

      host = uri.host.downcase
      LOCAL_HOSTS.include?(host) || host.end_with?(LOCAL_SUFFIX)
    end

    # @param url [String, nil]
    # @return [URI::Generic, nil] The parsed http(s) URL, or nil
    def self.parse(url)
      return nil unless url.is_a?(String)

      uri = URI.parse(url)
      return nil unless uri.scheme && HTTP_SCHEMES.include?(uri.scheme.downcase) && uri.host

      uri
    rescue URI::InvalidURIError
      nil
    end
    private_class_method :parse
  end
end
