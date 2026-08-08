require 'minitest/autorun'
require 'fileutils'
require 'tempfile'
require_relative '../../lib/managers/history_manager'
require_relative '../../lib/managers/autocomplete_manager'
require_relative '../../lib/repositories/history_repository'
require_relative '../support/test_clock'

# Integration test for the history flow without mocks
# Tests: Repository <-> HistoryManager <-> Domain <-> AutocompleteManager
class HistoryFlowTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @temp_db = Tempfile.new(['history', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @clock = TestClock.new(NOW)
    @repository = Repositories::HistoryRepository.new(db_path: @temp_db_path)
    @manager = Managers::HistoryManager.new(repository: @repository, clock: @clock)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@temp_db_path)
  end

  def test_happy_path_browsing_a_page_and_seeing_it_in_the_sidebar
    # 1. The user arrives at a page; WebKit reports it twice, once when the
    #    load finishes and again when the title settles.
    assert_equal :recorded, @manager.record_visit('https://example.com/article', 'An Article')
    assert_equal :duplicate, @manager.record_visit('https://example.com/article', 'An Article')

    # 2. The sidebar shows one visit, carrying everything it renders
    visit = @manager.recent_visits.first

    assert_equal 1, @manager.recent_visits.size
    assert_equal 'https://example.com/article', visit.uri
    assert_equal 'An Article', visit.display_title
    assert_equal NOW, visit.visited_at

    # 3. The favicon arrives later and reaches the same page
    assert @manager.update_favicon('https://example.com/article', 'PNGDATA')
    assert_equal 'PNGDATA', @manager.recent_visits.first.favicon

    # 4. Searching finds the page
    assert_equal ['https://example.com/article'], @manager.search('article').map(&:uri)

    # 5. Removing the visit empties the sidebar
    assert @manager.delete_visit(visit.id)
    assert_empty @manager.recent_visits
  end

  def test_revisiting_a_page_accumulates_onto_one_page_record
    @manager.record_visit('https://example.com/article', 'An Article')
    @clock.advance(3600)
    @manager.record_visit('https://example.com/other', 'Something Else')
    @clock.advance(3600)
    @manager.record_visit('https://example.com/article', 'An Article')

    assert_equal 3, @manager.recent_visits.size

    # Three visits, two pages: the search index has one row per URL
    assert_equal 2, @manager.search('example.com').size

    article = @manager.search('article').first

    assert_equal 2, article.visit_count
    assert_equal NOW + 7200, article.last_visited_at
  end

  def test_a_single_page_app_retitling_itself_records_a_second_visit
    # YouTube changes the title after the URL, which is a real second arrival
    @manager.record_visit('https://youtube.com/watch?v=abc', 'YouTube')
    @clock.advance(5)
    @manager.record_visit('https://youtube.com/watch?v=abc', 'A Video - YouTube')

    titles = @manager.recent_visits.map(&:display_title)

    assert_equal ['A Video - YouTube', 'YouTube'], titles
    assert_equal 1, @manager.search('youtube.com').size, 'still one page'
  end

  def test_history_feeds_autocomplete_suggestions
    @manager.record_visit('https://rarely.example.com', 'Rarely')
    5.times do |i|
      @clock.advance(60)
      @manager.record_visit('https://often.example.com', "Often #{i}")
    end

    autocomplete = AutocompleteManager.new(@manager, clock: TestClock.new(NOW + 300))

    # An empty query is the "just opened the URL bar" case: top candidates by
    # frecency, no fuzzy filtering involved.
    suggestions = autocomplete.suggest('')

    assert_equal 'https://often.example.com', suggestions.first[:uri]
    assert_operator suggestions.first[:frecency], :>, suggestions.last[:frecency]
    assert_includes suggestions.map { |s| s[:uri] }, 'https://rarely.example.com'
  end

  def test_a_url_the_history_cannot_key_is_skipped_without_stopping_the_next_one
    assert_equal :invalid_url, @manager.record_visit('about:blank', 'New Tab')
    assert_empty @manager.recent_visits

    assert_equal :recorded, @manager.record_visit('https://example.com/a', 'A Page')
    assert_equal 1, @manager.recent_visits.size
  end
end
