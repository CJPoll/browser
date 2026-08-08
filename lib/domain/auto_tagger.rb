require 'uri'

module Domain
  # Rule for automatic tag assignment based on pattern matching
  #
  # A rule defines patterns to match against metadata fields and the tag to
  # assign when a match is found.
  class AutoTagRule
    attr_reader :tag_name

    # Creates a new auto-tag rule
    #
    # @param tag_name [String] Tag to assign when rule matches
    # @param patterns [Array<String>] Substrings to match (case-insensitive)
    # @param fields [Symbol, Array<Symbol>] Metadata fields to check (:title, :channel)
    # @param site [String, nil] Optional site restriction (e.g., "youtube.com")
    #
    # @example Match "asmr" in title or channel for YouTube
    #   Domain::AutoTagRule.new(
    #     tag_name: "ASMR",
    #     patterns: ["asmr"],
    #     fields: [:title, :channel],
    #     site: "youtube.com"
    #   )
    def initialize(tag_name:, patterns:, fields:, site: nil)
      @tag_name = tag_name
      @patterns = Array(patterns)
      @fields = Array(fields)
      @site = site
    end

    # Checks if rule matches the given metadata
    #
    # @param metadata [Hash] Metadata with keys :title, :channel, :url
    # @return [Boolean] True if rule matches
    def matches?(metadata)
      return false if @site && !site_matches?(metadata[:url])

      @fields.any? do |field|
        value = metadata[field]
        next false if value.nil? || value.to_s.strip.empty?

        value_downcase = value.downcase
        @patterns.any? { |pattern| value_downcase.include?(pattern.downcase) }
      end
    end

    private

    # Checks if URL matches the site restriction
    #
    # @param url [String, nil] URL to check
    # @return [Boolean] True if URL is from the specified site
    def site_matches?(url)
      return false if url.nil?

      begin
        uri = URI.parse(url)
        host = uri.host&.downcase
        return false if host.nil?

        site_downcase = @site.downcase

        # Match exact, www prefix, or mobile prefix
        host == site_downcase ||
          host == "www.#{site_downcase}" ||
          host == "m.#{site_downcase}"
      rescue URI::InvalidURIError
        false
      end
    end
  end

  # Manages auto-tagging rules and applies them to queue entries
  #
  # AutoTagger holds a collection of rules and determines which tags should be
  # assigned based on entry metadata. The rules themselves are data -- they
  # come from `config/auto_tag_rules.json` by way of
  # `Adapters::AutoTagRulesStore`, so changing which channels get which tag is
  # an edit to a file, not to this class.
  class AutoTagger
    # Builds a tagger from rule data (as loaded from the rules file)
    #
    # Each entry is a hash with `tag_name`, `patterns`, `fields` and an
    # optional `site`. String and symbol keys are both accepted, so the same
    # method serves JSON data and a literal in a test.
    #
    # @param rules [Array<Hash>] Rule data
    # @return [AutoTagger] Tagger holding one rule per entry
    def self.from_rules(rules)
      tagger = new

      rules.each do |rule|
        data = rule.transform_keys(&:to_sym)

        tagger.add(
          tag_name: data.fetch(:tag_name),
          patterns: data.fetch(:patterns),
          fields: Array(data.fetch(:fields)).map(&:to_sym),
          site: data[:site]
        )
      end

      tagger
    end

    def initialize
      @rules = []
    end

    # Adds a rule to the tagger
    #
    # @param rule [AutoTagRule] Rule to add
    # @return [void]
    def add_rule(rule)
      @rules << rule
    end

    # Creates and adds a rule with the given parameters
    #
    # @param tag_name [String] Tag to assign when rule matches
    # @param patterns [Array<String>] Substrings to match
    # @param fields [Symbol, Array<Symbol>] Metadata fields to check
    # @param site [String, nil] Optional site restriction
    # @return [AutoTagRule] The created rule
    def add(tag_name:, patterns:, fields:, site: nil)
      rule = AutoTagRule.new(
        tag_name: tag_name,
        patterns: patterns,
        fields: fields,
        site: site
      )
      add_rule(rule)
      rule
    end

    # Returns all tags that should be assigned based on metadata
    #
    # @param metadata [Hash] Metadata with keys :title, :channel, :url
    # @return [Array<String>] Tag names to assign (unique, no duplicates)
    #
    # @example
    #   tagger = Domain::AutoTagger.new
    #   tagger.add(tag_name: "ASMR", patterns: ["asmr"], fields: :title)
    #   tagger.tags_for(title: "ASMR sounds", url: "https://youtube.com/...")
    #   # => ["ASMR"]
    def tags_for(metadata)
      @rules.select { |rule| rule.matches?(metadata) }.map(&:tag_name).uniq
    end

    # Returns number of rules
    #
    # @return [Integer] Number of rules
    def rule_count
      @rules.length
    end

    # Clears all rules
    #
    # @return [void]
    def clear
      @rules = []
    end
  end
end
