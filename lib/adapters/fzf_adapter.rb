require 'open3'

# FzfAdapter - Fuzzy string filtering using the fzf command-line tool
#
# This adapter shells out to fzf in filter mode to perform fuzzy matching
# on a list of strings. It's used for URL autocomplete where we want to
# find URLs that loosely match what the user is typing.
#
# fzf provides excellent fuzzy matching that:
# - Handles typos gracefully
# - Matches substrings anywhere in the string
# - Works across word boundaries
# - Returns results sorted by match quality
#
# @example Filter URLs by query
#   strings = ["Google\thttps://google.com", "GitHub\thttps://github.com"]
#   FzfAdapter.filter(strings, "git")  # => ["GitHub\thttps://github.com"]
#
module FzfAdapter
  # Filters strings using fzf's fuzzy matching algorithm
  #
  # @param strings [Array<String>] List of strings to filter
  # @param pattern [String] Fuzzy search pattern
  # @param limit [Integer] Maximum number of results to return (default: 10)
  # @return [Array<String>] Matching strings, sorted by fzf's scoring
  def self.filter(strings, pattern, limit: 10)
    return [] if strings.empty?

    # Empty or whitespace-only pattern returns first N strings (no filtering)
    if pattern.nil? || pattern.strip.empty?
      return strings.first(limit)
    end

    # Join strings with newlines for fzf input
    input = strings.join("\n")

    # Run fzf in filter mode
    # --filter: Non-interactive filter mode, prints matching lines
    # -i: Case-insensitive matching (smart-case: case-insensitive unless query has uppercase)
    # fzf returns exit code 0 for matches, 1 for no matches, 2+ for errors
    output, status = Open3.capture2("fzf", "-i", "--filter", pattern, stdin_data: input)

    # Exit code 1 means no matches (not an error)
    return [] unless status.success? || status.exitstatus == 1

    # Parse output and apply limit
    output.lines.map(&:chomp).first(limit)
  end
end
