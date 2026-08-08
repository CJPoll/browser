# frozen_string_literal: true

require_relative '../adapters/ipc_file'
require_relative '../domain/ipc_message'

module Managers
  # The conversation between a new browser invocation and the one already
  # running.
  #
  # Launching the browser a second time does not start a second browser: the
  # new process publishes its request and exits, and the running one picks it
  # up on its next poll. This manager owns both ends of that exchange and the
  # rule that keeps it safe -- a request is acted on once, because the running
  # instance remembers how recent the last one it took was.
  class IpcManager
    # Timestamp of the last request acted on. Starts at zero so a request
    # written just before the browser finished starting is still picked up.
    INITIAL_WATERMARK = 0.0

    # @param ipc_file [Adapters::IpcFile] Where requests are exchanged
    # @param clock [#call] Returns the current time
    def initialize(ipc_file: Adapters::IpcFile.new, clock: -> { Time.now })
      @ipc_file = ipc_file
      @clock = clock
      @watermark = INITIAL_WATERMARK
    end

    # Publishes a request for the running browser to act on
    #
    # @param url [String, nil] URL to open, or nil for a bare window
    # @param new_window [Boolean] Whether it should open in its own window
    # @return [Domain::IpcMessage] The published request
    def publish(url: nil, new_window: false)
      message = Domain::IpcMessage.new(
        url: url,
        timestamp: @clock.call.to_f,
        new_window: new_window
      )
      @ipc_file.write(message)
      message
    end

    # Takes the pending request, if it is one this instance has not acted on
    #
    # @return [Domain::IpcMessage, nil] The request, or nil if there is
    #   nothing new to act on
    def take_pending_request
      message = @ipc_file.read
      return nil unless message
      return nil unless message.newer_than?(@watermark)

      @watermark = message.timestamp
      @ipc_file.delete
      message
    end
  end
end
