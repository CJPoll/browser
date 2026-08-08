require 'minitest/autorun'
require 'stringio'
require_relative '../../lib/managers/history_manager'
require_relative '../support/test_clock'

# Stands in for Repositories::HistoryRepository.
class MockHistoryRepository
  attr_reader :recorded, :favicon_updates, :deleted_visits, :queries
  attr_accessor :favicon_update_result, :delete_result, :visits, :pages, :candidates

  def initialize
    @recorded = []
    @favicon_updates = []
    @deleted_visits = []
    @queries = []
    @favicon_update_result = true
    @delete_result = true
    @visits = []
    @pages = []
    @candidates = []
    @next_id = 1
  end

  def record_visit(url:, authority:, now:, title: nil, favicon_data: nil)
    @recorded << { url: url, authority: authority, title: title,
                   favicon_data: favicon_data, now: now }

    visit = Domain::Visit.new(id: @next_id, page_id: @next_id, visited_at: now, title: title)
    @next_id += 1
    visit
  end

  def update_favicon(url, favicon_data)
    @favicon_updates << [url, favicon_data]
    @favicon_update_result
  end

  def recent_visits(limit)
    @queries << [:recent_visits, limit]
    @visits
  end

  def search(query, limit)
    @queries << [:search, query, limit]
    @pages
  end

  def top_pages_by_frecency(limit)
    @queries << [:top_pages_by_frecency, limit]
    @candidates
  end

  def delete_visit(visit_id)
    @deleted_visits << visit_id
    @delete_result
  end

  def close
    @closed = true
  end

  def closed?
    @closed == true
  end
end

class HistoryManagerTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @repository = MockHistoryRepository.new
    @clock = TestClock.new(NOW)
    @manager = Managers::HistoryManager.new(repository: @repository, clock: @clock)
  end

  # === record_visit ===

  def test_record_visit_stores_the_visit
    assert_equal :recorded, @manager.record_visit('https://example.com/a', 'A Page')

    assert_equal 1, @repository.recorded.size
    assert_equal 'https://example.com/a', @repository.recorded.first[:url]
    assert_equal 'A Page', @repository.recorded.first[:title]
  end

  def test_record_visit_resolves_the_site_authority
    @manager.record_visit('https://example.com/a', 'A Page')

    assert_equal 'example.com', @repository.recorded.first[:authority]
  end

  def test_record_visit_keys_non_http_sites_on_host_and_port
    @manager.record_visit('ftp://files.example.com:21/pub', 'Files')

    assert_equal 'files.example.com:21', @repository.recorded.first[:authority]
  end

  def test_record_visit_stamps_the_current_time
    @clock.advance(90)

    @manager.record_visit('https://example.com/a', 'A Page')

    assert_equal NOW + 90, @repository.recorded.first[:now]
  end

  def test_record_visit_passes_favicon_data_through
    @manager.record_visit('https://example.com/a', 'A Page', favicon_data: 'PNGDATA')

    assert_equal 'PNGDATA', @repository.recorded.first[:favicon_data]
  end

  def test_record_visit_defaults_the_title_to_nil
    @manager.record_visit('https://example.com/a')

    assert_nil @repository.recorded.first[:title]
  end

  # === Deduplication ===

  def test_an_identical_repeat_is_not_recorded_twice
    @manager.record_visit('https://example.com/a', 'A Page')

    assert_equal :duplicate, @manager.record_visit('https://example.com/a', 'A Page')
    assert_equal 1, @repository.recorded.size
  end

  def test_a_new_title_for_the_same_url_is_a_new_visit
    @manager.record_visit('https://example.com/watch', 'YouTube')

    assert_equal :recorded, @manager.record_visit('https://example.com/watch', 'A Video')
    assert_equal 2, @repository.recorded.size
  end

  def test_a_new_url_with_the_same_title_is_a_new_visit
    @manager.record_visit('https://example.com/a', 'Same')

    assert_equal :recorded, @manager.record_visit('https://example.com/b', 'Same')
    assert_equal 2, @repository.recorded.size
  end

  def test_only_the_immediately_preceding_visit_is_deduplicated
    @manager.record_visit('https://example.com/a', 'A Page')
    @manager.record_visit('https://example.com/b', 'B Page')

    assert_equal :recorded, @manager.record_visit('https://example.com/a', 'A Page')
    assert_equal 3, @repository.recorded.size
  end

  def test_a_missing_title_takes_part_in_the_key
    @manager.record_visit('https://example.com/a', nil)

    assert_equal :duplicate, @manager.record_visit('https://example.com/a', nil)
    assert_equal :recorded, @manager.record_visit('https://example.com/a', 'A Page')
  end

  # === Unusable URLs ===

  def test_a_nil_url_is_rejected
    assert_equal :invalid_url, @manager.record_visit(nil, 'A Page')

    assert_empty @repository.recorded
  end

  def test_an_empty_url_is_rejected
    assert_equal :invalid_url, @manager.record_visit('', 'A Page')

    assert_empty @repository.recorded
  end

  def test_a_url_without_a_host_is_rejected
    assert_equal :invalid_url, @manager.record_visit('about:blank', 'Blank')

    assert_empty @repository.recorded
  end

  def test_a_malformed_url_is_rejected
    silence_warnings do
      assert_equal :invalid_url, @manager.record_visit('http://exa mple.com', 'Broken')
    end

    assert_empty @repository.recorded
  end

  def test_a_rejected_url_is_not_retried_on_an_identical_repeat
    @manager.record_visit('about:blank', 'Blank')

    assert_equal :duplicate, @manager.record_visit('about:blank', 'Blank')
  end

  def test_a_rejected_url_does_not_block_the_next_real_visit
    @manager.record_visit('about:blank', 'Blank')

    assert_equal :recorded, @manager.record_visit('https://example.com/a', 'A Page')
  end

  def test_a_nil_url_does_not_take_over_the_deduplication_key
    @manager.record_visit('https://example.com/a', 'A Page')
    @manager.record_visit(nil, nil)

    assert_equal :duplicate, @manager.record_visit('https://example.com/a', 'A Page')
  end

  # === update_favicon ===

  def test_update_favicon_writes_the_bytes
    assert @manager.update_favicon('https://example.com/a', 'PNGDATA')

    assert_equal [['https://example.com/a', 'PNGDATA']], @repository.favicon_updates
  end

  def test_update_favicon_reports_an_unknown_page
    @repository.favicon_update_result = false

    refute @manager.update_favicon('https://example.com/a', 'PNGDATA')
  end

  def test_update_favicon_ignores_a_missing_url
    refute @manager.update_favicon(nil, 'PNGDATA')

    assert_empty @repository.favicon_updates
  end

  def test_update_favicon_ignores_missing_bytes
    refute @manager.update_favicon('https://example.com/a', nil)

    assert_empty @repository.favicon_updates
  end

  def test_update_favicon_ignores_a_malformed_url
    silence_warnings do
      refute @manager.update_favicon('http://exa mple.com', 'PNGDATA')
    end

    assert_empty @repository.favicon_updates
  end

  # === Queries ===

  def test_recent_visits_comes_from_the_repository
    @repository.visits = [Domain::Visit.new(visited_at: NOW)]

    assert_equal @repository.visits, @manager.recent_visits(25)
    assert_equal [[:recent_visits, 25]], @repository.queries
  end

  def test_recent_visits_has_a_default_limit
    @manager.recent_visits

    assert_equal [[:recent_visits, 100]], @repository.queries
  end

  def test_search_comes_from_the_repository
    @repository.pages = [Domain::Page.new(uri: 'https://example.com/a')]

    assert_equal @repository.pages, @manager.search('example', 5)
    assert_equal [[:search, 'example', 5]], @repository.queries
  end

  def test_search_has_a_default_limit
    @manager.search('example')

    assert_equal [[:search, 'example', 50]], @repository.queries
  end

  def test_top_pages_by_frecency_comes_from_the_repository
    @repository.candidates = [Domain::Page.new(uri: 'https://example.com/a')]

    assert_equal @repository.candidates, @manager.top_pages_by_frecency(10)
    assert_equal [[:top_pages_by_frecency, 10]], @repository.queries
  end

  def test_top_pages_by_frecency_has_a_default_limit
    @manager.top_pages_by_frecency

    assert_equal [[:top_pages_by_frecency, 500]], @repository.queries
  end

  # === delete_visit ===

  def test_delete_visit_is_passed_through
    assert @manager.delete_visit(7)

    assert_equal [7], @repository.deleted_visits
  end

  def test_delete_visit_reports_an_unknown_visit
    @repository.delete_result = false

    refute @manager.delete_visit(999)
  end

  # === close ===

  def test_close_closes_the_repository
    @manager.close

    assert_predicate @repository, :closed?
  end

  private

  # The malformed-URL paths warn on purpose; keep the test output readable.
  def silence_warnings
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
