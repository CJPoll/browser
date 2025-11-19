require 'uri'

# Rule for automatic tag assignment based on pattern matching
#
# A rule defines patterns to match against metadata fields and the tag to assign
# when a match is found.
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
  #   AutoTagRule.new(
  #     tag_name: "ASMR",
  #     patterns: ["asmr"],
  #     fields: [:title, :channel],
  #     site: "youtube.com"
  #   )
  #
  # @example Match gaming terms in title for any site
  #   AutoTagRule.new(
  #     tag_name: "Gaming",
  #     patterns: ["gaming", "video games", "steam sale"],
  #     fields: :title
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
    # Check site restriction first
    if @site
      return false unless site_matches?(metadata[:url])
    end

    # Check each field for pattern matches
    @fields.any? do |field|
      value = metadata[field]
      next false if value.nil? || value.to_s.strip.empty?

      # Check if any pattern matches (case-insensitive substring)
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
# assigned based on entry metadata.
class AutoTagger
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
  #   tagger = AutoTagger.new
  #   tagger.add(tag_name: "ASMR", patterns: ["asmr"], fields: :title)
  #   tagger.add(tag_name: "Gaming", patterns: ["gaming"], fields: :title)
  #
  #   tags = tagger.tags_for(title: "ASMR for Gaming", url: "https://youtube.com/...")
  #   # => ["ASMR", "Gaming"]
  def tags_for(metadata)
    matching_tags = []

    @rules.each do |rule|
      matching_tags << rule.tag_name if rule.matches?(metadata)
    end

    matching_tags.uniq
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
