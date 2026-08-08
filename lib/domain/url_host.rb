require 'uri'

module Domain
  # Extracts the host portion of a URL.
  #
  # Three variants exist because the callers genuinely differ:
  #
  # - `host` -- the strict form used by the permission stores, which key their
  #   records on a hostname and want nil for anything that is not a URL.
  # - `host_or_bare_name` -- the same, but also accepts a hostname typed on its
  #   own ("claude.ai"), which is how notification permissions can be revoked
  #   from the permissions window where only the host is known.
  # - `authority` -- the history form, which keys sites on host for http(s) and
  #   on host:port for everything else, so that two services on one machine do
  #   not collapse into a single site.
  module UrlHost
    SCHEME_SEPARATOR = "://".freeze
    PATH_SEPARATOR = "/".freeze
    HTTP_SCHEMES = /^https?$/.freeze

    # Extracts the host from an absolute URL
    #
    # @param url [String, nil] URL to extract the host from
    # @return [String, nil] Host, or nil if absent, malformed, or host-less
    def self.host(url)
      return nil unless url

      begin
        URI.parse(url).host
      rescue URI::InvalidURIError
        nil
      end
    end

    # Extracts the host from an absolute URL, accepting a bare hostname as
    # already being a host
    #
    # @param url [String, nil] URL or bare hostname
    # @return [String, nil] Host, or nil if absent, malformed, or host-less
    def self.host_or_bare_name(url)
      return nil unless url
      return url if bare_hostname?(url)

      host(url)
    end

    # Builds the site key for a parsed URI: the host for http(s), host:port
    # otherwise
    #
    # @param uri [URI::Generic] Parsed URI
    # @return [String, nil] Authority, or nil if the URI has no host
    def self.authority(uri)
      return uri.host if uri.scheme =~ HTTP_SCHEMES
      return nil unless uri.host

      uri.port ? "#{uri.host}:#{uri.port}" : uri.host
    end

    # @param url [String] Candidate string
    # @return [Boolean] true if the string is a hostname rather than a URL
    def self.bare_hostname?(url)
      url.is_a?(String) && !url.include?(SCHEME_SEPARATOR) && !url.include?(PATH_SEPARATOR)
    end
    private_class_method :bare_hostname?
  end
end
