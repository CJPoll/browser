# frozen_string_literal: true

require 'uri'
require 'public_suffix'
require_relative 'url_host'
require_relative 'web_origin'

module Domain
  # Which of the listed logins belong to the site the user is on.
  #
  # The site is keyed on its registrable domain (eTLD+1): a login stored for
  # `google.com` fills on `accounts.google.com`, but one stored for
  # `google.com.evil.example` does not, and a bare public suffix (`co.uk`,
  # `github.io`) never matches by suffix alone. This is the same
  # `PublicSuffix.valid?/domain` precedent the passkey feature set in
  # Domain::RelyingPartyId, reused here so the two agree on what a "site" is.
  #
  # Scheme and port of the stored URL are ignored -- only secure origins reach
  # this call (the manager gates on Domain::WebOrigin.secure?), so an `http://`
  # stored URL still fills on the `https://` site.
  module LoginSiteMatch
    # The registrable domain for a host, or the host itself when it has no
    # known public suffix (loopback, IPs, single-label intranet names).
    #
    # @param host [String, nil]
    # @return [String, nil]
    def self.site_key(host)
      return nil if host.nil?

      normalized = host.to_s.downcase.sub(/\.\z/, '')
      return nil if normalized.empty?

      PublicSuffix.domain(normalized, default_rule: nil) || normalized
    end

    # @param site_key [String] the site key of the origin
    # @param url [String] a stored URL (may be a bare host, may have a scheme)
    # @return [Boolean] whether the URL belongs to the same site
    def self.matches?(site_key, url)
      host = host_of(url)
      return false unless host

      site_key(host) == site_key
    end

    # The candidates with at least one URL belonging to the origin's site, in
    # the order given.
    #
    # @param origin [String, nil]
    # @param candidates [Array<Domain::LoginCandidate>]
    # @return [Array<Domain::LoginCandidate>]
    def self.candidates_for(origin:, candidates:)
      host = Domain::WebOrigin.host(origin)
      return [] unless host

      key = site_key(host)
      candidates.select { |candidate| candidate.urls.any? { |url| matches?(key, url) } }
    end

    # 1Password stores a site as typed, so a URL may be a full address or a
    # bare host (`github.com`). A string that already carries a scheme but no
    # host (`mailto:x`) is not a site.
    #
    # @param url [String]
    # @return [String, nil]
    def self.host_of(url)
      return nil unless url.is_a?(String)

      host = Domain::UrlHost.host(url)
      return host if host
      return nil if url.include?('://')

      Domain::UrlHost.host("https://#{url}")
    rescue URI::Error
      nil
    end
    private_class_method :host_of
  end
end
