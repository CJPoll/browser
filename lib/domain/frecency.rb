# Frecency - Frequency + Recency scoring for URL autocomplete
#
# This module calculates a "frecency" score for URLs based on how often
# they've been visited and how recently. This combines two important signals:
#
# 1. Frequency: More visited pages are more likely to be wanted
# 2. Recency: Recently visited pages are more likely to be wanted
#
# The algorithm multiplies visit count by a recency weight that decays over time.
# This means a page visited 100 times a year ago will eventually be ranked
# below a page visited 10 times in the last hour.
#
# Weight tiers (based on Firefox's frecency algorithm):
# - Within 4 hours: 100 (very recent, highly relevant)
# - Within 1 day: 70
# - Within 1 week: 50
# - Within 1 month: 30
# - Within 3 months: 10
# - Older: 1 (base weight, still considered but heavily discounted)
#
# @example Calculate frecency score
#   visit_count = 10
#   now = clock.call.to_i                # supplied by the caller
#   last_visited = now - 3600            # 1 hour ago
#   score = Frecency.score(visit_count, last_visited, now)  # => 1000
#
module Frecency
  # Recency weight thresholds (in seconds) mapped to weights
  # Order matters: checked from smallest to largest threshold
  RECENCY_WEIGHTS = {
    4 * 3600 => 100,      # 4 hours
    86400 => 70,          # 1 day
    7 * 86400 => 50,      # 1 week
    30 * 86400 => 30,     # 1 month
    90 * 86400 => 10      # 3 months
  }.freeze

  # Calculates the frecency score for a page
  #
  # @param visit_count [Integer] Number of times the page has been visited
  # @param last_visited_at [Integer] Unix timestamp of last visit
  # @param now [Integer] Current Unix timestamp, supplied by the caller
  # @return [Integer] Frecency score (higher = more relevant)
  def self.score(visit_count, last_visited_at, now)
    seconds_ago = now - last_visited_at
    weight = recency_weight(seconds_ago)
    visit_count * weight
  end

  # Determines the recency weight based on how long ago the page was visited
  #
  # @param seconds_ago [Integer] Seconds since last visit
  # @return [Integer] Weight multiplier (1-100)
  def self.recency_weight(seconds_ago)
    RECENCY_WEIGHTS.each do |threshold, weight|
      return weight if seconds_ago <= threshold
    end
    1  # Base weight for very old entries
  end
end
