# frozen_string_literal: true

module Adapters
  # FileSystem answers questions about what is on disk.
  #
  # This is an Adapter: it exists so Managers can consult the filesystem
  # without holding a File call themselves, and so tests can substitute a
  # controllable stand-in instead of writing real files.
  class FileSystem
    # Whether a path already exists on disk
    #
    # @param path [String] Absolute path
    # @return [Boolean] True if a file or directory is there
    def exist?(path)
      File.exist?(path)
    end
  end
end
