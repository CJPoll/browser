require_relative 'test_helper'

class FilterVisualIndicatorsTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)
    @queue_list_view = QueueListView.new(@queue_manager, create_favicon_creator)

    # Add entries and tags
    @queue_manager.add("https://example.com/1", "Entry 1")
    @queue_manager.add("https://example.com/2", "Entry 2")
    @queue_manager.add("https://example.com/3", "Entry 3")

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

  def test_filters_active_returns_false_initially
    assert_equal false, @queue_list_view.filters_active?
  end

  def test_filters_active_returns_true_after_adding_filter
    @queue_list_view.add_filter_tag(@youtube_id)
    assert_equal true, @queue_list_view.filters_active?
  end

  def test_filters_active_returns_false_after_clearing
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.clear_all_filters
    assert_equal false, @queue_list_view.filters_active?
  end

  def test_active_filter_tag_names
    @queue_list_view.add_filter_tag(@youtube_id)
    @queue_list_view.add_filter_tag(@gaming_id)

    names = @queue_list_view.active_filter_tag_names

    assert_includes names, "YouTube"
    assert_includes names, "Gaming"
    assert_equal 2, names.length
  end

  def test_active_filter_tag_names_empty_when_no_filters
    names = @queue_list_view.active_filter_tag_names
    assert_equal [], names
  end
end
