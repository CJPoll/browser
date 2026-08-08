require_relative 'test_helper'

class FilterPopoverTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)
    @queue_list_view = create_queue_list_view(@queue_manager)

    # Add entries and tags
    @queue_manager.add("https://example.com/1", "Entry 1")
    @queue_manager.add("https://example.com/2", "Entry 2")
    @queue_manager.add("https://example.com/3", "Entry 3")

    entry1 = @queue_manager.find_by_url("https://example.com/1")
    entry2 = @queue_manager.find_by_url("https://example.com/2")
    entry3 = @queue_manager.find_by_url("https://example.com/3")

    @queue_manager.assign_tag_by_name(entry1.id, "YouTube")
    @queue_manager.assign_tag_by_name(entry1.id, "Gaming")
    @queue_manager.assign_tag_by_name(entry2.id, "YouTube")
    @queue_manager.assign_tag_by_name(entry3.id, "Gaming")
    @queue_manager.assign_tag_by_name(entry3.id, "Tutorial")
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_tag_usage_counts_correct
    counts = @queue_manager.tag_usage_counts

    # Convert to hash for easier assertion
    count_hash = counts.map { |c| [c.name, c.count] }.to_h

    assert_equal 2, count_hash['Gaming'], "Gaming should have 2 entries"
    assert_equal 1, count_hash['Tutorial'], "Tutorial should have 1 entry"
    assert_equal 2, count_hash['YouTube'], "YouTube should have 2 entries"
  end

  def test_tag_usage_counts_alphabetically_sorted
    counts = @queue_manager.tag_usage_counts

    tag_names = counts.map { |c| c.name }
    sorted_names = tag_names.sort_by(&:downcase)

    assert_equal sorted_names, tag_names, "Tags should be alphabetically sorted"
  end

  def test_initial_filter_state_empty
    assert_equal [], @queue_list_view.instance_variable_get(:@active_filter_tag_ids)
    assert_equal false, @queue_list_view.filters_active?
  end
end
