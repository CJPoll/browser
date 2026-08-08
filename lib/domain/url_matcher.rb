require 'uri'
require 'cgi'

module Domain
  # Decides whether two URLs refer to the same page, tolerating the query
  # parameters that sites add and remove while you are looking at them.
  #
  # Two URLs match when their scheme, host and path agree (trailing slash
  # ignored) and one URL's query parameters are a subset of the other's. The
  # subset test runs in both directions because either side can be the one
  # carrying the extras:
  #
  # - the stored URL has extras: YouTube appends `&pp=...` when you queue a
  #   link, then strips it during playback
  # - the live URL has extras: a `&t=90s` timestamp appears once playback starts
  #
  # Fragments are not compared. Neither is the port, which the base comparison
  # omits -- a wart preserved from the original implementation.
  module UrlMatcher
    # Checks whether two URLs refer to the same page
    #
    # @param url_a [String, nil] First URL
    # @param url_b [String, nil] Second URL
    # @return [Boolean] true if the URLs share a base and compatible parameters
    def self.match?(url_a, url_b)
      uri_a = parse(url_a)
      uri_b = parse(url_b)
      return false unless uri_a && uri_b
      return false unless base(uri_a) == base(uri_b)

      params_a = query_params(uri_a)
      params_b = query_params(uri_b)

      params_subset?(params_a, params_b) || params_subset?(params_b, params_a)
    end

    # Checks whether every parameter in subset appears in superset with the
    # same values
    #
    # @param subset [Hash{String => Array<String>}] Parameters expected to be contained
    # @param superset [Hash{String => Array<String>}] Parameters expected to contain them
    # @return [Boolean] true if superset contains all of subset
    def self.params_subset?(subset, superset)
      subset.all? { |key, values| superset[key] == values }
    end

    # @param url [String, nil] URL to parse
    # @return [URI::Generic, nil] Parsed URI, or nil if absent or malformed
    def self.parse(url)
      return nil unless url

      begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
    end
    private_class_method :parse

    # @param uri [URI::Generic] Parsed URI
    # @return [String] Scheme, host and path with any trailing slash removed
    def self.base(uri)
      "#{uri.scheme}://#{uri.host}#{uri.path}".sub(/\/$/, '')
    end
    private_class_method :base

    # @param uri [URI::Generic] Parsed URI
    # @return [Hash{String => Array<String>}] Query parameters, empty when absent
    def self.query_params(uri)
      uri.query ? CGI.parse(uri.query) : {}
    end
    private_class_method :query_params
  end
end
