require 'uri'

module Domain
  # Recognises the OAuth provider URLs that must open in a real popup window.
  #
  # These flows post their result back to `window.opener`, so routing them into
  # a tab breaks the handshake -- the opening page never learns the sign-in
  # succeeded. The browser gives them a floating window instead.
  module OauthPopup
    GOOGLE_HOST = 'accounts.google.com'.freeze
    APPLE_HOST = 'appleid.apple.com'.freeze
    MICROSOFT_HOSTS = ['login.microsoftonline.com', 'login.live.com'].freeze
    GITHUB_HOST = 'github.com'.freeze
    GITHUB_OAUTH_PATH_PREFIX = '/login/oauth'.freeze
    FIREBASE_HOST_SUFFIX = '.firebaseapp.com'.freeze
    FIREBASE_AUTH_PATH_FRAGMENT = 'auth'.freeze

    # Checks whether a URL belongs to an OAuth flow that needs its own window
    #
    # @param url [String, nil] URL to check
    # @return [Boolean] true if the URL is a known OAuth provider endpoint
    def self.popup?(url)
      return false unless url

      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError
        return false
      end

      host = uri.host&.downcase
      return false unless host

      return true if host == GOOGLE_HOST
      return true if host == APPLE_HOST
      return true if MICROSOFT_HOSTS.include?(host)
      return true if firebase_auth_handler?(host, uri.path)
      return true if github_oauth?(host, uri.path)

      false
    end

    # Firebase hosts a shared auth handler under a per-project subdomain
    #
    # @param host [String] Downcased host
    # @param path [String, nil] URL path
    # @return [Boolean] true if this is a Firebase auth handler URL
    def self.firebase_auth_handler?(host, path)
      host.end_with?(FIREBASE_HOST_SUFFIX) && !!path&.include?(FIREBASE_AUTH_PATH_FRAGMENT)
    end
    private_class_method :firebase_auth_handler?

    # GitHub serves both ordinary pages and OAuth from one host, so the path
    # decides
    #
    # @param host [String] Downcased host
    # @param path [String, nil] URL path
    # @return [Boolean] true if this is a GitHub OAuth URL
    def self.github_oauth?(host, path)
      host == GITHUB_HOST && !!path&.start_with?(GITHUB_OAUTH_PATH_PREFIX)
    end
    private_class_method :github_oauth?
  end
end
