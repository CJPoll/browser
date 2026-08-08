require_relative 'test_helper'

class TagPillFilterTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)
    @queue_list_view = create_queue_list_view(@queue_manager)

    # Add entries
    @queue_manager.add("https://example.com/1", "Entry 1")
    @queue_manager.add("https://example.com/2", "Entry 2")

    entry1 = @queue_manager.find_by_url("https://example.com/1")
    entry2 = @queue_manager.find_by_url("https://example.com/2")

    @youtube_id = @queue_manager.create_or_find_tag("YouTube").id
    @gaming_id = @queue_manager.create_or_find_tag("Gaming").id

    @queue_manager.assign_tag(entry1.id, @youtube_id)
    @queue_manager.assign_tag(entry1.id, @gaming_id)
    @queue_manager.assign_tag(entry2.id, @youtube_id)
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_filter_by_tag_name_sets_single_filter
    @queue_list_view.filter_by_tag_name("Gaming")

    active_ids = @queue_list_view.instance_variable_get(:@active_filter_tag_ids)

    assert_equal 1, active_ids.length
    assert_includes active_ids, @gaming_id
  end

  def test_filter_by_tag_name_replaces_existing_filters
    # First filter by YouTube
    @queue_list_view.filter_by_tag_name("YouTube")

    # Then filter by Gaming
    @queue_list_view.filter_by_tag_name("Gaming")

    active_ids = @queue_list_view.instance_variable_get(:@active_filter_tag_ids)

    # Should only have Gaming, not both
    assert_equal 1, active_ids.length
    assert_includes active_ids, @gaming_id
    assert_not_includes active_ids, @youtube_id
  end

  def test_filter_by_tag_name_shows_correct_entries
    @queue_list_view.filter_by_tag_name("Gaming")

    entries = @queue_list_view.send(:filtered_sorted_entries)
    urls = entries.map { |e| e.url }

    # Only Entry 1 has Gaming
    assert_equal 1, urls.length
    assert_includes urls, "https://example.com/1"
  end

  def test_filter_by_nonexistent_tag_does_nothing
    @queue_list_view.filter_by_tag_name("NonexistentTag")

    active_ids = @queue_list_view.instance_variable_get(:@active_filter_tag_ids)

    assert_equal 0, active_ids.length
  end
end
