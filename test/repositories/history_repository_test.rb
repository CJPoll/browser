require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/history_repository'

class HistoryRepositoryTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @test_db_path = '/tmp/test_history.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::HistoryRepository.new(db_path: @test_db_path)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  def record(url: 'https://example.com/a', authority: 'example.com',
             title: 'A Page', favicon_data: nil, now: NOW)
    @repository.record_visit(url: url, authority: authority, title: title,
                             favicon_data: favicon_data, now: now)
  end

  # === record_visit ===

  def test_record_visit_returns_the_stored_visit
    visit = record

    refute_nil visit.id
    refute_nil visit.page_id
    assert_equal NOW, visit.visited_at
    assert_equal 'A Page', visit.title
  end

  def test_record_visit_creates_the_page
    record

    page = @repository.recent_visits.first.page

    assert_equal 'https://example.com/a', page.uri
    assert_equal 'A Page', page.title
    assert_equal 1, page.visit_count
  end

  def test_recording_the_same_url_twice_reuses_the_page
    first = record
    second = record(now: NOW + 60)

    refute_equal first.id, second.id
    assert_equal first.page_id, second.page_id
    assert_equal 2, @repository.recent_visits.first.page.visit_count
  end

  def test_recording_updates_the_pages_last_visited_time
    record
    record(now: NOW + 3600)

    assert_equal NOW + 3600, @repository.search('example').first.last_visited_at
  end

  def test_recording_two_urls_on_one_authority_shares_the_site
    record(url: 'https://example.com/a')
    record(url: 'https://example.com/b')

    site_ids = @repository.recent_visits.map { |visit| visit.page.site_id }

    assert_equal 1, site_ids.uniq.size
  end

  def test_recording_a_different_authority_creates_a_second_site
    record(url: 'https://example.com/a', authority: 'example.com')
    record(url: 'https://other.com/a', authority: 'other.com')

    site_ids = @repository.recent_visits.map { |visit| visit.page.site_id }

    assert_equal 2, site_ids.uniq.size
  end

  def test_recording_keeps_an_existing_title_when_the_new_one_is_missing
    record(title: 'A Page')
    record(title: nil, now: NOW + 60)

    assert_equal 'A Page', @repository.recent_visits.first.page.title
  end

  def test_recording_with_favicon_data_stores_it
    record(favicon_data: 'PNGDATA')

    assert_equal 'PNGDATA', @repository.recent_visits.first.page.favicon
  end

  def test_recording_without_favicon_data_keeps_the_stored_favicon
    record(favicon_data: 'PNGDATA')
    record(favicon_data: nil, now: NOW + 60)

    assert_equal 'PNGDATA', @repository.recent_visits.first.page.favicon
  end

  # === update_favicon ===

  def test_update_favicon_writes_the_bytes
    record

    assert @repository.update_favicon('https://example.com/a', 'PNGDATA')
    assert_equal 'PNGDATA', @repository.recent_visits.first.page.favicon
  end

  def test_update_favicon_reports_an_unknown_page
    refute @repository.update_favicon('https://nowhere.example.com', 'PNGDATA')
  end

  # === recent_visits ===

  def test_recent_visits_is_newest_first
    record(url: 'https://example.com/old', title: 'Old', now: NOW)
    record(url: 'https://example.com/new', title: 'New', now: NOW + 60)

    assert_equal %w[New Old], @repository.recent_visits.map(&:title)
  end

  def test_recent_visits_honours_the_limit
    3.times { |i| record(url: "https://example.com/#{i}", now: NOW + i) }

    assert_equal 2, @repository.recent_visits(2).size
  end

  def test_recent_visits_returns_visits_carrying_their_page
    record(favicon_data: 'PNGDATA')

    visit = @repository.recent_visits.first

    assert_instance_of Domain::Visit, visit
    assert_instance_of Domain::Page, visit.page
    assert_equal 'https://example.com/a', visit.uri
    assert_equal 'PNGDATA', visit.favicon
  end

  def test_recent_visits_is_empty_for_a_fresh_database
    assert_empty @repository.recent_visits
  end

  # === search ===

  def test_search_matches_the_uri
    record(url: 'https://example.com/ruby-guide', title: 'Guide')

    assert_equal ['https://example.com/ruby-guide'], @repository.search('ruby').map(&:uri)
  end

  def test_search_matches_the_title
    record(url: 'https://example.com/a', title: 'Ruby Guide')

    assert_equal 1, @repository.search('Guide').size
  end

  def test_search_matches_the_authority
    record(url: 'https://ruby-lang.org/a', authority: 'ruby-lang.org', title: 'Home')

    assert_equal 1, @repository.search('ruby-lang').size
  end

  def test_search_returns_one_row_per_page_however_many_visits
    record
    record(now: NOW + 60)

    assert_equal 1, @repository.search('example').size
  end

  def test_search_results_carry_the_page_id_for_deletion
    record

    refute_nil @repository.search('example').first.id
  end

  def test_search_results_omit_the_favicon
    # Known wart, preserved: the search projection does not select the favicon,
    # so search rows render without one while recent visits render with one.
    record(favicon_data: 'PNGDATA')

    assert_nil @repository.search('example').first.favicon
  end

  def test_search_honours_the_limit
    3.times { |i| record(url: "https://example.com/#{i}") }

    assert_equal 2, @repository.search('example', 2).size
  end

  def test_search_with_no_matches_is_empty
    record

    assert_empty @repository.search('nothing-like-this')
  end

  # === top_pages_by_frecency ===

  def test_top_pages_by_frecency_ranks_frequent_pages_first
    record(url: 'https://example.com/rare', title: 'Rare')
    5.times { |i| record(url: 'https://example.com/common', title: 'Common', now: NOW + i) }

    assert_equal 'Common', @repository.top_pages_by_frecency.first.title
  end

  def test_top_pages_by_frecency_carries_the_scoring_inputs
    record(favicon_data: 'PNGDATA')

    page = @repository.top_pages_by_frecency.first

    assert_equal 'https://example.com/a', page.uri
    assert_equal 'A Page', page.title
    assert_equal 'PNGDATA', page.favicon
    assert_equal 1, page.visit_count
    assert_equal NOW, page.last_visited_at
  end

  def test_top_pages_by_frecency_honours_the_limit
    3.times { |i| record(url: "https://example.com/#{i}") }

    assert_equal 2, @repository.top_pages_by_frecency(2).size
  end

  def test_top_pages_by_frecency_is_empty_for_a_fresh_database
    assert_empty @repository.top_pages_by_frecency
  end

  # === delete_visit ===

  def test_delete_visit_removes_only_that_visit
    first = record(now: NOW)
    record(now: NOW + 60)

    assert @repository.delete_visit(first.id)
    assert_equal 1, @repository.recent_visits.size
  end

  def test_delete_visit_reports_an_unknown_id
    refute @repository.delete_visit(999)
  end

  def test_delete_visit_reports_a_nil_id
    refute @repository.delete_visit(nil)
  end

  # === delete_visits_older_than ===

  def test_delete_visits_older_than_removes_earlier_visits
    record(url: 'https://example.com/old', now: NOW)
    record(url: 'https://example.com/new', now: NOW + 7200)

    @repository.delete_visits_older_than(NOW + 3600)

    assert_equal ['https://example.com/new'], @repository.recent_visits.map(&:uri)
  end

  def test_delete_visits_older_than_removes_pages_left_without_visits
    record(url: 'https://example.com/old', now: NOW)

    @repository.delete_visits_older_than(NOW + 3600)

    assert_empty @repository.search('example')
  end

  # === clear_all ===

  def test_clear_all_empties_the_history
    record

    @repository.clear_all

    assert_empty @repository.recent_visits
    assert_empty @repository.search('example')
  end

  # === Persistence ===

  def test_an_existing_database_is_reopened_rather_than_reset
    record
    @repository.close

    reopened = Repositories::HistoryRepository.new(db_path: @test_db_path)

    assert_equal 1, reopened.recent_visits.size
  ensure
    reopened&.close
  end
end
