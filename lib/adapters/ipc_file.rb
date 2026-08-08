# frozen_string_literal: true

require 'fileutils'
require_relative '../domain/ipc_message'

module Adapters
  # The file two browser instances talk through.
  #
  # A second invocation writes its request here and exits; the primary
  # instance polls the file and acts on what it finds. Only one request is
  # ever pending -- a newer one overwrites the last.
  class IpcFile
    DEFAULT_DIR = File.join(Dir.home, '.local/share/toy-browser')
    FILENAME = 'pending-url'

    # @return [String] Full path of the file, for diagnostics
    attr_reader :path

    # @param data_dir [String] Directory holding the browser's data
    def initialize(data_dir: DEFAULT_DIR)
      FileUtils.mkdir_p(data_dir)
      @path = File.join(data_dir, FILENAME)
    end

    # Publishes a request for the primary instance
    #
    # @param message [Domain::IpcMessage] The request to publish
    # @return [void]
    def write(message)
      File.write(@path, message.serialize)
    end

    # Reads the pending request, if there is one
    #
    # @return [Domain::IpcMessage, nil] The request, or nil if none is pending
    def read
      return nil unless File.exist?(@path)

      Domain::IpcMessage.parse(File.read(@path))
    end

    # Clears the pending request
    #
    # @return [void]
    def delete
      File.delete(@path) if File.exist?(@path)
    end
  end
end
