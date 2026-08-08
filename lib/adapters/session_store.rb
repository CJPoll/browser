# frozen_string_literal: true

require 'json'
require 'fileutils'

module Adapters
  # The JSON file a closing window leaves for the next one to open.
  #
  # Storage only: which tabs are worth saving and which one to select are
  # decided by `Domain::SessionSnapshot` before anything reaches this class.
  # Loading consumes the file, so a session is restored exactly once.
  class SessionStore
    DEFAULT_DIR = File.join(Dir.home, '.local/share/toy-browser')
    FILENAME = 'session.json'

    # @param data_dir [String] Directory holding the browser's data
    def initialize(data_dir: DEFAULT_DIR)
      FileUtils.mkdir_p(data_dir)
      @session_file = File.join(data_dir, FILENAME)
    end

    # Writes the session, replacing any previous one
    #
    # @param session [Hash] Session contents
    # @return [Boolean] True if it was written
    def save(session)
      File.write(@session_file, JSON.pretty_generate(session))
      true
    rescue StandardError => e
      warn "Failed to save session: #{e.message}"
      false
    end

    # Reads the saved session and clears it
    #
    # @return [Hash, nil] Session contents, or nil if there was none to read
    def load
      return nil unless File.exist?(@session_file)

      session = JSON.parse(File.read(@session_file))
      File.delete(@session_file)
      session
    rescue StandardError => e
      warn "Failed to load session: #{e.message}"
      nil
    end
  end
end
