require_relative 'test_helper'

class SortingTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = QueueManager.new(@temp_db_path)
    @queue_list_view = QueueListView.new(@queue_manager, create_favicon_creator)

    # Add entries with different dates
    @queue_manager.add("https://example.com/a", "Zebra Video")
    @queue_manager.add("https://example.com/b", "Alpha Video")
    @queue_manager.add("https://example.com/c", "Middle Video")

    # Set dates (Unix timestamps)
    @queue_manager.update_date("https://example.com/a", 1704067200)  # 2024-01-01
    @queue_manager.update_date("https://example.com/b", 1717200000)  # 2024-06-01
    # Entry C has NULL date (not set)
  end

  def teardown
    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      db.close unless db.closed? rescue nil
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_default_sort_is_position
    assert_equal :position, @queue_list_view.current_sort_mode

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    titles = entries.map { |e| e['title'] }

    # Position order is insertion order
    assert_equal ["Zebra Video", "Alpha Video", "Middle Video"], titles
  end

  def test_sort_by_title_alphabetical
    @queue_list_view.set_sort_mode(:title)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    titles = entries.map { |e| e['title'] }

    assert_equal ["Alpha Video", "Middle Video", "Zebra Video"], titles
  end

  def test_sort_by_title_case_insensitive
    # Add entry with lowercase title
    @queue_manager.add("https://example.com/d", "aardvark Video")

    @queue_list_view.set_sort_mode(:title)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    titles = entries.map { |e| e['title'] }

    # aardvark should come first
    assert_equal "aardvark Video", titles.first
  end

  def test_sort_by_date_newest_first
    @queue_list_view.set_sort_mode(:date_published)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    titles = entries.map { |e| e['title'] }

    # Alpha Video (June) is newest, then Zebra (Jan), then Middle (NULL last)
    assert_equal ["Alpha Video", "Zebra Video", "Middle Video"], titles
  end

  def test_sort_by_date_nulls_last
    @queue_list_view.set_sort_mode(:date_published)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    last_entry = entries.last

    # Middle Video has NULL date, should be last
    assert_equal "Middle Video", last_entry['title']
    assert_nil last_entry['date']
  end

  def test_sort_combined_with_filter
    # Add tag to some entries
    entry_a = @queue_manager.find_by_url("https://example.com/a")
    entry_b = @queue_manager.find_by_url("https://example.com/b")

    tag_id = @queue_manager.create_or_find_tag("TestTag")
    @queue_manager.assign_tag(entry_a['id'], tag_id)
    @queue_manager.assign_tag(entry_b['id'], tag_id)

    # Apply filter
    @queue_list_view.add_filter_tag(tag_id)

    # Apply title sort
    @queue_list_view.set_sort_mode(:title)

    entries = @queue_list_view.send(:get_filtered_sorted_entries)
    titles = entries.map { |e| e['title'] }

    # Only entries with tag, sorted by title
    assert_equal ["Alpha Video", "Zebra Video"], titles
  end
end
