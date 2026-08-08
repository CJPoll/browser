# frozen_string_literal: true

require 'json'
require 'fileutils'

module Adapters
  # The JSON file the browser's preferences live in.
  #
  # Storage only: it reads and writes a hash. What the keys mean, and what a
  # missing key falls back to, is `Managers::SettingsManager`'s business.
  class SettingsStore
    DEFAULT_DIR = File.join(Dir.home, '.local/share/toy-browser')
    FILENAME = 'settings.json'

    # @param data_dir [String] Directory holding the browser's data
    def initialize(data_dir: DEFAULT_DIR)
      FileUtils.mkdir_p(data_dir)
      @settings_file = File.join(data_dir, FILENAME)
    end

    # Writes the settings, replacing the previous ones
    #
    # @param settings [Hash] Settings to store
    # @return [Boolean] True if they were written
    def save(settings)
      File.write(@settings_file, JSON.pretty_generate(settings))
      true
    rescue StandardError => e
      warn "Failed to save settings: #{e.message}"
      false
    end

    # Reads the stored settings
    #
    # @return [Hash] Stored settings, empty on first run or if unreadable
    def load
      return {} unless File.exist?(@settings_file)

      JSON.parse(File.read(@settings_file))
    rescue StandardError => e
      warn "Failed to load settings: #{e.message}"
      {}
    end
  end
end
