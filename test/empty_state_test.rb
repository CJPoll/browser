require_relative 'test_helper'

class EmptyStateTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = QueueManager.new(@temp_db_path)
    @queue_list_view = QueueListView.new(@queue_manager, create_favicon_creator)

    # Add entries with different tags (no overlap)
    @queue_manager.add("https://example.com/1", "Entry 1")
    @queue_manager.add("https://example.com/2", "Entry 2")

    entry1 = @queue_manager.find_by_url("https://example.com/1")
    entry2 = @queue_manager.find_by_url("https://example.com/2")

    @youtube_id = @queue_manager.create_or_find_tag("YouTube")
    @gaming_id = @queue_manager.create_or_find_tag("Gaming")

    @queue_manager.assign_tag(entry1['id'], @youtube_id)
    @queue_manager.assign_tag(entry2['id'], @gaming_id)
  end

  def teardown
    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      db.close unless db.closed? rescue nil
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_empty_entries_when_filter_matches_nothing
    # Filter by both tags - no entry has both
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)

    assert_equal 0, entries.length
    assert_equal true, @queue_list_view.filters_active?
  end

  def test_entries_return_after_clear_filters
    # Apply impossible filter
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)

    # Clear filters
    @queue_list_view.clear_all_filters

    entries = @queue_list_view.send(:get_filtered_sorted_entries)

    assert_equal 2, entries.length
  end
end
