# frozen_string_literal: true

module Adapters
  # Hands a URI or path to the desktop, which decides what opens it.
  #
  # This is how `spotify://` reaches Spotify and how "Show in folder" reaches
  # the file manager. The adapter performs the effect only -- whether a URI
  # belongs to another application is a Domain question
  # (`Domain::ExternalSchemes`) answered before we get here.
  class UriOpener
    COMMAND = 'xdg-open'

    # Runs a command as argv, never through a shell.
    SYSTEM_RUNNER = ->(*argv) { system(*argv) }

    # @param runner [#call] Receives the command and its arguments
    def initialize(runner: SYSTEM_RUNNER)
      @runner = runner
    end

    # Opens a URI or filesystem path with the desktop's handler
    #
    # @param target [String, nil] URI or path to open
    # @return [Boolean] True if the handler was launched
    def open(target)
      return false if target.nil? || target.to_s.strip.empty?

      !!@runner.call(COMMAND, target)
    end
  end
end
