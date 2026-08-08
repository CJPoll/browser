module Domain
  # URL schemes that belong to other applications rather than to the web view.
  #
  # A URL with one of these schemes is handed to the desktop's URI opener
  # instead of being loaded, so that `spotify://` opens Spotify and
  # `vscode://` opens the editor.
  #
  # Known limitation: detection splits on "://", so the opaque schemes in the
  # list (mailto, tel, sms) are never actually recognised. This is preserved
  # from the two handler implementations this module replaced.
  module ExternalSchemes
    SCHEME_SEPARATOR = "://".freeze

    SCHEMES = %w[
      warp spotify discord slack steam zoommtg zoomus
      tg telegram signal viber whatsapp
      vscode vscodium cursor
      obsidian notion
      mailto tel sms
    ].freeze

    # Checks whether a URL should be delegated to an external application
    #
    # @param url [String, nil] The URL to check
    # @return [Boolean] true if the URL uses an external scheme
    def self.external?(url)
      return false unless url
      return false unless url.include?(SCHEME_SEPARATOR)

      SCHEMES.include?(url.split(SCHEME_SEPARATOR).first.downcase)
    end
  end
end
