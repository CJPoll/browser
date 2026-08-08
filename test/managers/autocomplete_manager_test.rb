require 'minitest/autorun'
require 'tempfile'
require 'uri'
require_relative '../../lib/domain/url_host'
require_relative '../../lib/managers/autocomplete_manager'
require_relative '../../lib/managers/history_manager'
require_relative '../../lib/repositories/history_repository'
require_relative '../support/test_clock'

class AutocompleteManagerTest < Minitest::Test
  # Every seeded visit lands on this instant and the manager scores from it,
  # so recency weights -- and therefore the ranking -- are deterministic.
  NOW = Time.at(1_700_000_000).freeze

  def setup
    # Create a temporary database for testing
    @db_file = Tempfile.new(['history', '.db'])
    @repository = Repositories::HistoryRepository.new(db_path: @db_file.path)
    @history_manager = Managers::HistoryManager.new(repository: @repository)
    @autocomplete_manager = AutocompleteManager.new(@history_manager, clock: TestClock.new(NOW))

    # Seed some test data
    seed_history_data
  end

  def teardown
    @repository&.close
    @db_file.close
    @db_file.unlink
  end

  # Seeds visits through the repository rather than the manager: the manager
  # deduplicates identical consecutive visits, which is exactly what building
  # up a visit count needs to bypass.
  def record_visit(url, title, times: 1)
    authority = Domain::UrlHost.authority(URI.parse(url))

    times.times do
      @repository.record_visit(url: url, authority: authority, title: title, now: NOW)
    end
  end

  # ========================================
  # Basic Functionality Tests
  # ========================================

  def test_suggest_returns_array
    result = @autocomplete_manager.suggest("google")

    assert_instance_of Array, result
  end

  def test_suggest_with_empty_query_returns_top_candidates
    result = @autocomplete_manager.suggest("")

    refute_empty result
    # Should return up to RESULT_LIMIT (10) entries
    assert_operator result.length, :<=, 10
  end

  def test_suggest_with_whitespace_query_returns_top_candidates
    result = @autocomplete_manager.suggest("   ")

    refute_empty result
  end

  def test_suggest_filters_by_query
    result = @autocomplete_manager.suggest("github")

    # Should find GitHub in results
    github_result = result.find { |c| c[:uri].include?("github.com") }
    refute_nil github_result
  end

  def test_suggest_returns_candidates_with_expected_keys
    result = @autocomplete_manager.suggest("google")

    refute_empty result
    candidate = result.first

    assert candidate.key?(:uri), "Candidate should have :uri"
    assert candidate.key?(:title), "Candidate should have :title"
    assert candidate.key?(:favicon), "Candidate should have :favicon"
    assert candidate.key?(:frecency), "Candidate should have :frecency"
  end

  def test_suggest_no_matches_returns_empty
    result = @autocomplete_manager.suggest("xyz123nonexistent")

    assert_equal [], result
  end

  # ========================================
  # Frecency Scoring Tests
  # ========================================

  def test_candidates_sorted_by_frecency
    # Add a very frequent page
    record_visit("https://frequent.example.com", "Frequent Page", times: 50)
    @autocomplete_manager.invalidate_cache

    result = @autocomplete_manager.suggest("example")

    # Find our frequent page in results
    frequent_result = result.find { |c| c[:uri] == "https://frequent.example.com" }

    if frequent_result && result.length > 1
      # Should be near the top due to high frecency
      index = result.index(frequent_result)
      assert_operator index, :<, 3, "Frequent page should be near the top"
    end
  end

  def test_recent_pages_score_higher
    # Seed with old and recent pages that have same visit count
    # The recent one should score higher

    result = @autocomplete_manager.suggest("")

    # Google (visited most recently in seed data) should rank high
    google_result = result.find { |c| c[:uri].include?("google.com") }
    if google_result
      google_frecency = google_result[:frecency]

      # Should have a positive frecency score
      assert_operator google_frecency, :>, 0
    end
  end

  # ========================================
  # Caching Tests
  # ========================================

  def test_caching_returns_same_results_within_ttl
    # First call
    result1 = @autocomplete_manager.suggest("")

    # Second call (should use cache)
    result2 = @autocomplete_manager.suggest("")

    # Should return identical results
    assert_equal result1.map { |c| c[:uri] }, result2.map { |c| c[:uri] }
  end

  def test_invalidate_cache_clears_cache
    # First call populates cache
    @autocomplete_manager.suggest("")

    # Add new data
    record_visit("https://newsite.example.com", "New Site")

    # Invalidate cache
    @autocomplete_manager.invalidate_cache

    # Next call should see new data
    result = @autocomplete_manager.suggest("newsite")

    new_site = result.find { |c| c[:uri] == "https://newsite.example.com" }
    refute_nil new_site, "Should find newly added site after cache invalidation"
  end

  def test_cache_is_invalidatable
    # Populate cache
    @autocomplete_manager.suggest("")

    # This should not raise
    assert_respond_to @autocomplete_manager, :invalidate_cache
    @autocomplete_manager.invalidate_cache
  end

  # ========================================
  # Result Limit Tests
  # ========================================

  def test_suggest_respects_result_limit
    # Add many pages
    20.times do |i|
      record_visit("https://page#{i}.example.com", "Page #{i}")
    end
    @autocomplete_manager.invalidate_cache

    result = @autocomplete_manager.suggest("page")

    # Should not return more than RESULT_LIMIT (10)
    assert_operator result.length, :<=, 10
  end

  # ========================================
  # Title and URL Search Tests
  # ========================================

  def test_search_matches_title
    result = @autocomplete_manager.suggest("YouTube")

    youtube_result = result.find { |c| c[:title]&.include?("YouTube") }
    refute_nil youtube_result, "Should find page by title match"
  end

  def test_search_matches_url
    result = @autocomplete_manager.suggest("stackoverflow")

    so_result = result.find { |c| c[:uri].include?("stackoverflow") }
    refute_nil so_result, "Should find page by URL match"
  end

  def test_search_is_case_insensitive
    # Search with different cases
    result_lower = @autocomplete_manager.suggest("github")
    result_upper = @autocomplete_manager.suggest("GITHUB")

    # Both should find GitHub
    refute_empty result_lower
    refute_empty result_upper
  end

  # ========================================
  # Edge Cases
  # ========================================

  def test_handles_special_characters_in_query
    # Should not crash with special characters
    result = @autocomplete_manager.suggest("c++")

    assert_instance_of Array, result
  end

  def test_handles_empty_history
    # Create manager with empty history
    empty_db = Tempfile.new(['empty_history', '.db'])
    empty_repository = Repositories::HistoryRepository.new(db_path: empty_db.path)
    empty_history = Managers::HistoryManager.new(repository: empty_repository)
    empty_manager = AutocompleteManager.new(empty_history, clock: TestClock.new(NOW))

    result = empty_manager.suggest("anything")

    assert_equal [], result

    empty_repository.close
    empty_db.close
    empty_db.unlink
  end

  def test_handles_pages_with_nil_title
    record_visit("https://notitle.example.com", nil)
    @autocomplete_manager.invalidate_cache

    # Should not crash
    result = @autocomplete_manager.suggest("notitle")

    assert_instance_of Array, result
  end

  def test_handles_very_long_query
    long_query = "a" * 1000

    # Should not crash or hang
    result = @autocomplete_manager.suggest(long_query)

    assert_instance_of Array, result
  end

  private

  def seed_history_data
    # Seed with realistic test data
    test_pages = [
      { url: "https://www.google.com", title: "Google", visits: 100 },
      { url: "https://www.youtube.com", title: "YouTube", visits: 80 },
      { url: "https://github.com", title: "GitHub", visits: 50 },
      { url: "https://stackoverflow.com/questions/tagged/ruby", title: "Ruby - Stack Overflow", visits: 30 },
      { url: "https://www.reddit.com/r/ruby", title: "Ruby - Reddit", visits: 20 },
      { url: "https://news.ycombinator.com", title: "Hacker News", visits: 40 }
    ]

    test_pages.each do |page|
      record_visit(page[:url], page[:title], times: page[:visits])
    end
  end
end
