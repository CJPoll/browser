# frozen_string_literal: true

require_relative 'url_host'

module Domain
  # What the browser should do when a site asks for a permission it may
  # already hold: allow it outright, ask the user, or stay out of the way.
  #
  # The same three answers cover the camera and microphone, web notifications,
  # and trusting a certificate the TLS check rejected -- what differs between
  # them is only which store was consulted, which is the Manager's business.
  #
  # A request from a page with no host is *ignored* rather than blocked: there
  # is nothing to record a grant against, so the browser leaves the request to
  # WebKit's own default rather than deciding on the user's behalf.
  class PermissionDecision
    ALLOW = :allow
    PROMPT = :prompt
    IGNORE = :ignore

    attr_reader :action, :host

    # Decides what to do with a permission request
    #
    # @param url [String, nil] Page (or failing URI) the request came from
    # @param granted [Boolean] Whether the site already holds the permission
    # @return [PermissionDecision]
    def self.for(url:, granted:)
      host = Domain::UrlHost.host(url)
      return new(action: IGNORE) unless host

      new(action: granted ? ALLOW : PROMPT, host: host)
    end

    # @param action [Symbol] One of ALLOW, PROMPT, IGNORE
    # @param host [String, nil] Host the decision is about
    def initialize(action:, host: nil)
      raise ArgumentError, 'action is required' if action.nil?

      @action = action
      @host = host
      freeze
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { action: action, host: host }
    end

    def ==(other)
      other.is_a?(PermissionDecision) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
