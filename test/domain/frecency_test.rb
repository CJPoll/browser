require 'minitest/autorun'
require_relative '../../lib/domain/frecency'

class FrecencyTest < Minitest::Test
  def setup
    # Use a fixed "now" for predictable test results
    @now = 1700000000  # Some arbitrary Unix timestamp
  end

  # ========================================
  # Recency Weight Tests
  # ========================================

  def test_recency_weight_within_4_hours
    # 2 hours ago = 100 weight
    seconds_ago = 2 * 3600
    assert_equal 100, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_at_4_hour_boundary
    # Exactly 4 hours = 100 weight
    seconds_ago = 4 * 3600
    assert_equal 100, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_between_4_hours_and_1_day
    # 12 hours ago = 70 weight
    seconds_ago = 12 * 3600
    assert_equal 70, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_at_1_day_boundary
    # Exactly 1 day = 70 weight
    seconds_ago = 86400
    assert_equal 70, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_between_1_day_and_1_week
    # 3 days ago = 50 weight
    seconds_ago = 3 * 86400
    assert_equal 50, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_at_1_week_boundary
    # Exactly 1 week = 50 weight
    seconds_ago = 7 * 86400
    assert_equal 50, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_between_1_week_and_1_month
    # 2 weeks ago = 30 weight
    seconds_ago = 14 * 86400
    assert_equal 30, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_at_1_month_boundary
    # Exactly 30 days = 30 weight
    seconds_ago = 30 * 86400
    assert_equal 30, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_between_1_month_and_3_months
    # 2 months ago = 10 weight
    seconds_ago = 60 * 86400
    assert_equal 10, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_at_3_month_boundary
    # Exactly 90 days = 10 weight
    seconds_ago = 90 * 86400
    assert_equal 10, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_older_than_3_months
    # 6 months ago = 1 weight (base)
    seconds_ago = 180 * 86400
    assert_equal 1, Frecency.recency_weight(seconds_ago)
  end

  def test_recency_weight_very_old
    # 1 year ago = 1 weight (base)
    seconds_ago = 365 * 86400
    assert_equal 1, Frecency.recency_weight(seconds_ago)
  end

  # ========================================
  # Score Calculation Tests
  # ========================================

  def test_score_recent_single_visit
    # Single visit 1 hour ago
    visit_count = 1
    last_visited_at = @now - (1 * 3600)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # 1 visit * 100 weight = 100
    assert_equal 100, score
  end

  def test_score_recent_multiple_visits
    # 10 visits, most recent 2 hours ago
    visit_count = 10
    last_visited_at = @now - (2 * 3600)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # 10 visits * 100 weight = 1000
    assert_equal 1000, score
  end

  def test_score_old_single_visit
    # Single visit 2 months ago
    visit_count = 1
    last_visited_at = @now - (60 * 86400)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # 1 visit * 10 weight = 10
    assert_equal 10, score
  end

  def test_score_old_multiple_visits
    # 50 visits, most recent 6 months ago
    visit_count = 50
    last_visited_at = @now - (180 * 86400)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # 50 visits * 1 weight = 50
    assert_equal 50, score
  end

  # ========================================
  # Comparison Tests (Core Use Case)
  # ========================================

  def test_recent_beats_old_same_visits
    # Same number of visits, but one is recent and one is old
    visit_count = 5
    recent_last_visited = @now - (1 * 3600)   # 1 hour ago
    old_last_visited = @now - (60 * 86400)    # 2 months ago

    recent_score = Frecency.score(visit_count, recent_last_visited, @now)
    old_score = Frecency.score(visit_count, old_last_visited, @now)

    # Recent: 5 * 100 = 500, Old: 5 * 10 = 50
    assert_operator recent_score, :>, old_score
    assert_equal 500, recent_score
    assert_equal 50, old_score
  end

  def test_frequent_beats_rare_same_recency
    # Same recency, but different visit counts
    last_visited_at = @now - (12 * 3600)  # 12 hours ago
    frequent_visits = 20
    rare_visits = 2

    frequent_score = Frecency.score(frequent_visits, last_visited_at, @now)
    rare_score = Frecency.score(rare_visits, last_visited_at, @now)

    # Frequent: 20 * 70 = 1400, Rare: 2 * 70 = 140
    assert_operator frequent_score, :>, rare_score
    assert_equal 1400, frequent_score
    assert_equal 140, rare_score
  end

  def test_very_frequent_old_can_beat_rare_recent
    # Edge case: A very frequently visited old page might beat a rarely visited recent page
    very_frequent_visits = 100
    very_frequent_last_visited = @now - (60 * 86400)  # 2 months ago

    rare_visits = 1
    rare_last_visited = @now - (1 * 3600)  # 1 hour ago

    frequent_score = Frecency.score(very_frequent_visits, very_frequent_last_visited, @now)
    rare_score = Frecency.score(rare_visits, rare_last_visited, @now)

    # Frequent: 100 * 10 = 1000, Rare: 1 * 100 = 100
    assert_operator frequent_score, :>, rare_score
    assert_equal 1000, frequent_score
    assert_equal 100, rare_score
  end

  def test_moderate_recent_beats_moderate_old
    # More realistic comparison
    recent_visits = 10
    recent_last_visited = @now - (2 * 3600)  # 2 hours ago

    old_visits = 15
    old_last_visited = @now - (30 * 86400)  # 1 month ago

    recent_score = Frecency.score(recent_visits, recent_last_visited, @now)
    old_score = Frecency.score(old_visits, old_last_visited, @now)

    # Recent: 10 * 100 = 1000, Old: 15 * 30 = 450
    assert_operator recent_score, :>, old_score
    assert_equal 1000, recent_score
    assert_equal 450, old_score
  end

  # ========================================
  # Clock Injection
  # ========================================

  def test_score_requires_an_injected_now
    # Domain code never reads the clock; callers supply the current time.
    assert_raises(ArgumentError) do
      Frecency.score(1, @now - 3600)
    end
  end

  # ========================================
  # Edge Cases
  # ========================================

  def test_zero_visits
    visit_count = 0
    last_visited_at = @now - (1 * 3600)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # 0 visits * any weight = 0
    assert_equal 0, score
  end

  def test_negative_seconds_ago_treated_as_recent
    # Future timestamp (negative seconds ago) - treat as very recent
    visit_count = 1
    last_visited_at = @now + 3600  # 1 hour in the future (clock skew scenario)

    score = Frecency.score(visit_count, last_visited_at, @now)

    # Negative seconds_ago will be treated as within first bucket (100 weight)
    assert_equal 100, score
  end
end
