require 'cgi'

module Domain
  # Decides what the user meant by the text they typed into the URL bar.
  #
  # The classification is deliberately returned as a symbol rather than a
  # finished URL: turning `~/notes.md` into a `file://` URL requires expanding
  # the home directory, which reads the environment and therefore belongs to
  # the caller, not to Domain.
  module UrlClassifier
    ABSOLUTE_URL_PREFIXES = ["http://", "https://", "file://"].freeze
    ABSOLUTE_PATH_PREFIX = "/".freeze
    HOME_PATH_PREFIX = "~/".freeze
    SEARCH_URL_TEMPLATE = "https://www.google.com/search?q=%s".freeze

    # Text with a dot-separated first token and no spaces reads as a hostname
    DOMAIN_PATTERN = /^[\w-]+\.[\w.-]+/.freeze

    # Text naming a network location outright: an explicit scheme, or a
    # loopback/private address that would never be a search term
    EXPLICIT_ADDRESS_PATTERN = /^(localhost|127\.|192\.168\.|10\.)/.freeze
    SCHEME_SEPARATOR = "://".freeze

    # Classifies URL-bar text
    #
    # @param text [String] Text as typed, already stripped of surrounding space
    # @return [Symbol] :absolute_url, :absolute_path, :home_path, :domain, or :search
    def self.classify(text)
      return :absolute_url if text.start_with?(*ABSOLUTE_URL_PREFIXES)
      return :absolute_path if text.start_with?(ABSOLUTE_PATH_PREFIX)
      return :home_path if text.start_with?(HOME_PATH_PREFIX)
      return :domain if text.match?(DOMAIN_PATTERN) && !text.include?(' ')

      :search
    end

    # Builds the search-engine URL for a query
    #
    # @param query [String] Search terms
    # @return [String] Search URL
    def self.search_url(query)
      format(SEARCH_URL_TEMPLATE, CGI.escape(query))
    end

    # Checks whether the text unambiguously names a network location, and so
    # should not be treated as a search query worth autocompleting
    #
    # @param text [String, nil] Text as typed
    # @return [Boolean] true if the text is an explicit address
    def self.explicit_address?(text)
      return false unless text

      text.include?(SCHEME_SEPARATOR) || text.match?(EXPLICIT_ADDRESS_PATTERN)
    end
  end
end
