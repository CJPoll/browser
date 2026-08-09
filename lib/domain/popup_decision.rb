# frozen_string_literal: true

require_relative 'oauth_popup'
require_relative 'url_host'

module Domain
  # What the browser should do about a page's request to open a popup.
  #
  # Two questions decide it, and they are independent: *may* this site open
  # popups at all (a stored permission the Manager fetches), and *where* does
  # this particular URL belong if it may (an OAuth provider needs a real
  # window, everything else is happier as a tab).
  #
  # A popup with nothing to open -- no URL, or a URL naming no host -- is
  # blocked without a bar. There would be no host to name in the bar, and no
  # host to record a permission against if the user said yes.
  class PopupDecision
    OAUTH_WINDOW = :oauth_window
    NEW_TAB = :new_tab
    PROMPT = :prompt
    BLOCK = :block

    attr_reader :action, :url, :host

    # Decides what to do with a popup request
    #
    # @param url [String, nil] Destination the page asked to open
    # @param allowed [Boolean] Whether the site may open popups
    # @return [PopupDecision]
    def self.for(url:, allowed:)
      return new(action: BLOCK) if url.nil?

      host = Domain::UrlHost.host(url)

      if allowed
        new(action: Domain::OauthPopup.popup?(url) ? OAUTH_WINDOW : NEW_TAB, url: url, host: host)
      elsif host
        new(action: PROMPT, url: url, host: host)
      else
        new(action: BLOCK, url: url)
      end
    end

    # @param action [Symbol] One of OAUTH_WINDOW, NEW_TAB, PROMPT, BLOCK
    # @param url [String, nil] Destination, where there is one
    # @param host [String, nil] Host to name in the bar and grant against
    def initialize(action:, url: nil, host: nil)
      raise ArgumentError, 'action is required' if action.nil?

      @action = action
      @url = url
      @host = host
      freeze
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { action: action, url: url, host: host }
    end

    def ==(other)
      other.is_a?(PopupDecision) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
