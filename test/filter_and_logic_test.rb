require_relative 'test_helper'

class FilterAndLogicTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = QueueManager.new(@temp_db_path)
    @queue_list_view = QueueListView.new(@queue_manager, create_favicon_creator)

    # Add entries
    @queue_manager.add("https://example.com/1", "Entry 1")
    @queue_manager.add("https://example.com/2", "Entry 2")
    @queue_manager.add("https://example.com/3", "Entry 3")

    @entry1 = @queue_manager.find_by_url("https://example.com/1")
    @entry2 = @queue_manager.find_by_url("https://example.com/2")
    @entry3 = @queue_manager.find_by_url("https://example.com/3")

    # Assign tags
    @youtube_id = @queue_manager.create_or_find_tag("YouTube")
    @gaming_id = @queue_manager.create_or_find_tag("Gaming")
    @tutorial_id = @queue_manager.create_or_find_tag("Tutorial")

    @queue_manager.assign_tag(@entry1['id'], @youtube_id)
    @queue_manager.assign_tag(@entry1['id'], @gaming_id)
    @queue_manager.assign_tag(@entry2['id'], @youtube_id)
    @queue_manager.assign_tag(@entry3['id'], @gaming_id)
    @queue_manager.assign_tag(@entry3['id'], @tutorial_id)
  end

  def teardown
    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      db.close unless db.closed? rescue nil
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_single_tag_filter
    @queue_list_view.add_filter_tag(@youtube_id)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    urls = entries.map { |e| e['url'] }

    assert_includes urls, "https://example.com/1"
    assert_includes urls, "https://example.com/2"
    assert_not_includes urls, "https://example.com/3"
  end

  def test_multiple_tag_filter_and_logic
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    urls = entries.map { |e| e['url'] }

    # Only Entry 1 has both YouTube AND Gaming
    assert_equal 1, urls.length
    assert_includes urls, "https://example.com/1"
  end

  def test_remove_filter_tag
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)

    # Remove YouTube filter
    @queue_list_view.remove_filter_tag(@youtube_id)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    urls = entries.map { |e| e['url'] }

    # Entry 1 and Entry 3 both have Gaming
    assert_equal 2, urls.length
    assert_includes urls, "https://example.com/1"
    assert_includes urls, "https://example.com/3"
  end

  def test_clear_all_filters
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)
    @queue_list_view.clear_all_filters

    entries = @queue_list_view.send(:get_filtered_sorted_entries)

    # All 3 entries returned
    assert_equal 3, entries.length
  end

  def test_filter_returns_no_matches
    # No entry has both YouTube and Tutorial
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@tutorial_id)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)

    assert_equal 0, entries.length
  end
end
