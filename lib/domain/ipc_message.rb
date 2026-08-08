# frozen_string_literal: true

module Domain
  # A request from a second browser instance to the primary one.
  #
  # Launching the browser while it is already running does not start a second
  # process: the new invocation writes one of these to a file the primary
  # instance polls, and exits. The message says which URL to open, when it was
  # written, and whether it wants its own window.
  #
  # The timestamp is what makes the exchange safe: the primary instance
  # remembers the last one it acted on, so re-reading the same file cannot open
  # the same URL twice.
  class IpcMessage
    SEPARATOR = "\n"
    NEW_WINDOW_MARKER = 'true'

    attr_reader :url, :timestamp, :new_window

    # @param url [String, nil] URL to open; empty for a bare new-window request
    # @param timestamp [Float] Unix time the request was written
    # @param new_window [Boolean] Whether the request wants its own window
    def initialize(url:, timestamp:, new_window: false)
      raise ArgumentError, 'timestamp is required' if timestamp.nil?

      @url = url.to_s
      @timestamp = timestamp.to_f
      @new_window = !!new_window
      freeze
    end

    # Reads a message out of the raw file contents
    #
    # Never raises: a partially written or empty file parses to a message with
    # a zero timestamp, which no watermark will ever consider fresh.
    #
    # @param content [String, nil] Raw file contents
    # @return [Domain::IpcMessage, nil] The message, or nil if there was none
    def self.parse(content)
      return nil if content.nil?

      parts = content.split(SEPARATOR)
      new(url: parts[0].to_s, timestamp: parts[1].to_f, new_window: parts[2] == NEW_WINDOW_MARKER)
    end

    # @return [String] The wire form: url, timestamp and window flag, one per line
    def serialize
      [url, timestamp, new_window].join(SEPARATOR)
    end

    # @return [Boolean] Whether the request names a URL to open
    def url?
      !url.empty?
    end

    # @return [Boolean] Whether the request wants its own window
    def new_window?
      new_window
    end

    # Whether this request was written after the last one that was acted on
    #
    # @param watermark [Float] Timestamp of the last request acted on
    # @return [Boolean]
    def newer_than?(watermark)
      timestamp > watermark
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      { url: url, timestamp: timestamp, new_window: new_window }
    end

    def ==(other)
      other.is_a?(IpcMessage) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
