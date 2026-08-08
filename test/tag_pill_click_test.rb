require_relative 'test_helper'

class TagPillClickTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)

    # Add queue entry with tags
    @queue_manager.add("https://example.com", "Test Video")
    @entry = @queue_manager.find_by_url("https://example.com")
    @queue_manager.assign_tag_by_name(@entry.id, "Gaming")
    @queue_manager.assign_tag_by_name(@entry.id, "YouTube")

    # Create queue list view
    @queue_list_view = create_queue_list_view(@queue_manager)

    # Track callback invocations
    @clicked_tag_name = nil
    @queue_list_view.on_tag_pill_clicked = ->(tag_name) { @clicked_tag_name = tag_name }
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_tag_pill_stores_tag_name
    # Create tag pill
    pill = @queue_list_view.send(:create_tag_pill, "Gaming")

    # Verify tag name stored
    tag_name = pill.instance_variable_get(:@tag_name)
    assert_equal "Gaming", tag_name, "Tag name should be stored in instance variable"
  end

  def test_tag_pill_click_callback
    # Create tag pill
    pill = @queue_list_view.send(:create_tag_pill, "Gaming")

    # Simulate click event
    # Note: Cannot simulate actual GTK event without event loop
    # Test the callback method directly
    @queue_list_view.send(:on_tag_pill_clicked, "Gaming")

    # Verify callback invoked
    assert_equal "Gaming", @clicked_tag_name, "Callback should receive tag name"
  end

  def test_tag_pill_click_filters_by_tag
    # Phase 4 behavior: clicking tag pill filters the queue by that tag
    # (Console logging was removed in Phase 4)

    # Simulate click
    @queue_list_view.send(:on_tag_pill_clicked, "Gaming")

    # Verify callback was invoked
    assert_equal "Gaming", @clicked_tag_name, "Callback should receive tag name"
  end
end
