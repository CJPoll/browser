require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/queue_database'
require_relative '../../lib/repositories/queue_repository'

# Repositories are never mocked -- these run against a real SQLite file.
class QueueRepositoryTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze
  PUBLISHED_AT = Time.at(1_600_000_000).freeze

  def setup
    @db_path = "/tmp/test_queue_repository_#{Process.pid}.db"
    FileUtils.rm_f(@db_path)
    @database = Repositories::QueueDatabase.new(db_path: @db_path)
    @repository = Repositories::QueueRepository.new(@database)
  end

  def teardown
    @database&.close
    FileUtils.rm_f(@db_path)
  end

  def build_entry(url, **overrides)
    Domain::QueueEntry.new(**{ url: url, added_at: ADDED_AT }.merge(overrides))
  end

  def add(url, **overrides)
    @repository.add(build_entry(url, **overrides))
  end

  # === Schema ===

  def test_uses_the_pre_existing_queue_entries_table
    add('https://example.com/1')

    rows = @database.execute('SELECT url, position, added_at FROM queue_entries')

    assert_equal 1, rows.length
    assert_equal 'https://example.com/1', rows.first['url']
  end

  def test_records_survive_reconnection
    add('https://example.com/1', title: 'One')
    @database.close

    reopened = Repositories::QueueDatabase.new(db_path: @db_path)
    begin
      assert_equal 'One', Repositories::QueueRepository.new(reopened).all.first.title
    ensure
      reopened.close
    end
  end

  # === add ===

  def test_add_returns_the_stored_entry_with_an_id_and_position
    stored = add('https://example.com/1', title: 'One')

    refute_nil stored.id
    assert_equal 1, stored.position
    assert_equal 'One', stored.title
  end

  def test_add_appends_to_the_back_of_the_queue
    add('https://example.com/1')
    add('https://example.com/2')

    assert_equal [1, 2], @repository.all.map(&:position)
  end

  def test_add_returns_nil_for_a_url_already_queued
    add('https://example.com/1')

    assert_nil add('https://example.com/1')
  end

  def test_add_leaves_the_queue_untouched_when_the_url_is_already_queued
    add('https://example.com/1')
    add('https://example.com/1')

    assert_equal 1, @repository.count
  end

  def test_add_stores_the_favicon_bytes
    add('https://example.com/1', favicon_data: 'PNGDATA')

    assert_equal 'PNGDATA', @repository.all.first.favicon_data
  end

  def test_add_round_trips_the_queued_time
    add('https://example.com/1')

    assert_equal ADDED_AT, @repository.all.first.added_at
  end

  # === Queries ===

  def test_all_is_empty_for_a_new_database
    assert_equal [], @repository.all
  end

  def test_all_is_ordered_by_position
    add('https://example.com/1')
    second = add('https://example.com/2')
    add('https://example.com/3')
    @repository.move(second.id, 1)

    assert_equal %w[https://example.com/2 https://example.com/1 https://example.com/3],
                 @repository.all.map(&:url)
  end

  def test_first_returns_the_front_of_the_queue
    add('https://example.com/1')
    add('https://example.com/2')

    assert_equal 'https://example.com/1', @repository.first.url
  end

  def test_first_returns_nil_for_an_empty_queue
    assert_nil @repository.first
  end

  def test_find_by_id_returns_the_entry
    stored = add('https://example.com/1')

    assert_equal stored, @repository.find_by_id(stored.id)
  end

  def test_find_by_id_returns_nil_for_an_unknown_id
    assert_nil @repository.find_by_id(999)
  end

  def test_find_by_id_returns_nil_for_a_nil_id
    assert_nil @repository.find_by_id(nil)
  end

  def test_find_by_url_matches_exactly
    add('https://example.com/1')

    assert_equal 'https://example.com/1', @repository.find_by_url('https://example.com/1').url
  end

  def test_find_by_url_does_not_match_a_different_query_string
    add('https://example.com/1')

    assert_nil @repository.find_by_url('https://example.com/1?t=90s')
  end

  def test_find_by_url_returns_nil_for_a_nil_url
    assert_nil @repository.find_by_url(nil)
  end

  def test_find_by_position_returns_the_entry_at_that_rank
    add('https://example.com/1')
    add('https://example.com/2')

    assert_equal 'https://example.com/2', @repository.find_by_position(2).url
  end

  def test_find_by_position_returns_nil_past_the_end
    add('https://example.com/1')

    assert_nil @repository.find_by_position(2)
  end

  def test_find_all_by_ids_returns_entries_in_queue_order
    first = add('https://example.com/1')
    second = add('https://example.com/2')
    third = add('https://example.com/3')

    assert_equal [first, second, third],
                 @repository.find_all_by_ids([third.id, first.id, second.id])
  end

  def test_find_all_by_ids_ignores_unknown_ids
    stored = add('https://example.com/1')

    assert_equal [stored], @repository.find_all_by_ids([stored.id, 999])
  end

  def test_find_all_by_ids_returns_nothing_for_an_empty_list
    add('https://example.com/1')

    assert_equal [], @repository.find_all_by_ids([])
  end

  def test_count_reports_the_queue_length
    add('https://example.com/1')
    add('https://example.com/2')

    assert_equal 2, @repository.count
  end

  # === remove ===

  def test_remove_deletes_the_entry
    stored = add('https://example.com/1')

    assert @repository.remove(stored.id)
    assert_equal 0, @repository.count
  end

  def test_remove_closes_the_gap_in_the_ordering
    add('https://example.com/1')
    second = add('https://example.com/2')
    add('https://example.com/3')

    @repository.remove(second.id)

    assert_equal [1, 2], @repository.all.map(&:position)
    assert_equal %w[https://example.com/1 https://example.com/3], @repository.all.map(&:url)
  end

  def test_remove_reports_false_for_an_unknown_id
    refute @repository.remove(999)
  end

  def test_remove_reports_false_for_a_nil_id
    refute @repository.remove(nil)
  end

  # === move ===

  def test_move_shifts_the_entries_it_passes_going_up
    add('https://example.com/1')
    add('https://example.com/2')
    third = add('https://example.com/3')

    @repository.move(third.id, 1)

    assert_equal %w[https://example.com/3 https://example.com/1 https://example.com/2],
                 @repository.all.map(&:url)
    assert_equal [1, 2, 3], @repository.all.map(&:position)
  end

  def test_move_shifts_the_entries_it_passes_going_down
    first = add('https://example.com/1')
    add('https://example.com/2')
    add('https://example.com/3')

    @repository.move(first.id, 3)

    assert_equal %w[https://example.com/2 https://example.com/3 https://example.com/1],
                 @repository.all.map(&:url)
    assert_equal [1, 2, 3], @repository.all.map(&:position)
  end

  def test_move_clamps_a_position_above_the_queue
    first = add('https://example.com/1')
    add('https://example.com/2')

    @repository.move(first.id, 99)

    assert_equal 2, @repository.find_by_id(first.id).position
  end

  def test_move_clamps_a_position_below_the_queue
    add('https://example.com/1')
    second = add('https://example.com/2')

    @repository.move(second.id, -5)

    assert_equal 1, @repository.find_by_id(second.id).position
  end

  def test_move_to_the_current_position_is_a_no_op
    stored = add('https://example.com/1')

    assert @repository.move(stored.id, 1)
    assert_equal 1, @repository.find_by_id(stored.id).position
  end

  def test_move_reports_false_for_an_unknown_id
    refute @repository.move(999, 1)
  end

  def test_move_reports_false_for_a_nil_id
    refute @repository.move(nil, 1)
  end

  # === Metadata updates ===

  def test_update_title_writes_the_title
    add('https://example.com/1')

    @repository.update_title('https://example.com/1', 'Fetched title')

    assert_equal 'Fetched title', @repository.find_by_url('https://example.com/1').title
  end

  def test_update_favicon_writes_the_bytes
    add('https://example.com/1')

    @repository.update_favicon('https://example.com/1', 'PNGDATA')

    assert_equal 'PNGDATA', @repository.find_by_url('https://example.com/1').favicon_data
  end

  def test_update_published_at_round_trips_the_time
    add('https://example.com/1')

    @repository.update_published_at('https://example.com/1', PUBLISHED_AT)

    assert_equal PUBLISHED_AT, @repository.find_by_url('https://example.com/1').published_at
  end

  def test_published_at_is_nil_until_it_is_written
    add('https://example.com/1')

    assert_nil @repository.find_by_url('https://example.com/1').published_at
  end

  def test_updating_an_unqueued_url_changes_nothing
    add('https://example.com/1')

    @repository.update_title('https://elsewhere.test', 'Nope')

    assert_nil @repository.find_by_url('https://example.com/1').title
  end

  # === clear_all ===

  def test_clear_all_empties_the_queue
    add('https://example.com/1')
    add('https://example.com/2')

    @repository.clear_all

    assert_equal 0, @repository.count
  end
end
