# frozen_string_literal: true

require_relative 'url_host'

module Domain
  # A notification a web page asked the desktop to show.
  #
  # The page supplies a title and a body and may omit either; the host it is
  # running on is what the notification is attributed to, so the user can tell
  # who is talking to them. A page whose URL names no host -- `about:blank`, a
  # document loaded from a string -- sends as `unknown` rather than anonymously.
  class WebNotification
    DEFAULT_TITLE = 'Web Notification'
    UNKNOWN_HOST = 'unknown'

    attr_reader :title, :body, :host

    # Builds a notification from what the page provided
    #
    # @param title [String, nil] Title the page set
    # @param body [String, nil] Body the page set
    # @param page_url [String, nil] URL of the page that sent it
    # @return [WebNotification]
    def self.for(title:, body:, page_url:)
      new(
        title: title || DEFAULT_TITLE,
        body: body || '',
        host: Domain::UrlHost.host(page_url) || UNKNOWN_HOST
      )
    end

    # @param title [String] Title to show
    # @param body [String] Body to show
    # @param host [String] Host the notification is attributed to
    def initialize(title:, body:, host:)
      raise ArgumentError, 'title is required' if title.nil?
      raise ArgumentError, 'body is required' if body.nil?
      raise ArgumentError, 'host is required' if host.nil?

      @title = title
      @body = body
      @host = host
      freeze
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { title: title, body: body, host: host }
    end

    def ==(other)
      other.is_a?(WebNotification) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
