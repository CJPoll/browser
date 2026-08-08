# frozen_string_literal: true

require 'json'

module Adapters
  # Reads the auto-tagging rules that ship with the browser.
  #
  # The rules are data (`config/auto_tag_rules.json`), so adding a channel or a
  # keyword is an edit to that file. This adapter does nothing but read it;
  # turning the data into rules is `Domain::AutoTagger.from_rules`.
  class AutoTagRulesStore
    DEFAULT_PATH = File.expand_path('../../config/auto_tag_rules.json', __dir__)

    attr_reader :path

    # @param path [String] Path to the rules file
    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Loads the rule data
    #
    # A missing or unreadable rules file means no auto-tagging, not a browser
    # that fails to start, so failures are warned about and reported as an
    # empty rule set.
    #
    # @return [Array<Hash>] One hash per rule, as written in the file
    def load
      return [] unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      rules = data.is_a?(Hash) ? data['rules'] : data

      rules.is_a?(Array) ? rules : []
    rescue JSON::ParserError, SystemCallError, IOError => e
      warn "Error loading auto-tag rules from #{@path}: #{e.message}"
      []
    end
  end
end
