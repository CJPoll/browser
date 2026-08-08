require_relative 'test_helper'

class QueueListViewTagsTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)

    # Use test helper method for favicon creator
    @favicon_creator = create_favicon_creator

    @queue_list_view = QueueListView.new(@queue_manager, @favicon_creator)
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_tag_pills_display_alphabetically
    # Add queue entry
    @queue_manager.add("https://example.com/video", "Test Video")
    entry = @queue_manager.find_by_url("https://example.com/video")

    # Create and assign tags (in non-alphabetical order)
    @queue_manager.assign_tag_by_name(entry.id, "Zebra")
    @queue_manager.assign_tag_by_name(entry.id, "Alpha")
    @queue_manager.assign_tag_by_name(entry.id, "Gamma")

    # Refresh view
    @queue_list_view.refresh

    # Get first row
    row = @queue_list_view.list_widget.children.first
    assert_not_nil row, "Row should exist"

    # Find tags_box in row (third child of vbox)
    event_box = row.children.first
    hbox = event_box.children.first
    vbox = hbox.children[1]  # Second child is vbox
    tags_box = vbox.children[2]  # Third child is tags_box

    # Get tag pills (EventBox widgets)
    tag_pills = tags_box.children.select { |child| child.is_a?(Gtk::EventBox) }

    # Verify 3 pills displayed
    assert_equal 3, tag_pills.length, "Should show 3 tag pills"

    # Verify alphabetical order
    tag_names = tag_pills.map do |pill|
      label = pill.children.first
      label.text
    end
    assert_equal ["Alpha", "Gamma", "Zebra"], tag_names, "Tags should be alphabetically sorted"
  end

  def test_tag_pills_truncate_after_three
    # Add queue entry
    @queue_manager.add("https://example.com/video", "Test Video")
    entry = @queue_manager.find_by_url("https://example.com/video")

    # Create and assign 5 tags
    (1..5).each do |i|
      @queue_manager.assign_tag_by_name(entry.id, "Tag#{i}")
    end

    # Refresh view
    @queue_list_view.refresh

    # Get tags_box
    row = @queue_list_view.list_widget.children.first
    event_box = row.children.first
    hbox = event_box.children.first
    vbox = hbox.children[1]
    tags_box = vbox.children[2]

    # Get tag pills and "+N more" label
    tag_pills = tags_box.children.select { |child| child.is_a?(Gtk::EventBox) }
    more_label = tags_box.children.find { |child| child.is_a?(Gtk::Label) }

    # Verify only 3 pills shown
    assert_equal 3, tag_pills.length, "Should show only 3 tag pills"

    # Verify "+2 more" label exists
    assert_not_nil more_label, "+N more label should exist"
    assert_equal "+2 more", more_label.text, "Should show +2 more"
  end

  def test_tag_color_generation_deterministic
    # Same tag name should always produce same color
    color1 = @queue_list_view.tag_color_rgb("YouTube")
    color2 = @queue_list_view.tag_color_rgb("YouTube")

    assert_equal color1, color2, "Same tag should produce same color"

    # Different tags should produce different colors (usually)
    color3 = @queue_list_view.tag_color_rgb("Gaming")
    refute_equal color1, color3, "Different tags should produce different colors"
  end

  def test_tag_color_case_insensitive
    # Case-insensitive tag names should produce same color
    color1 = @queue_list_view.tag_color_rgb("YouTube")
    color2 = @queue_list_view.tag_color_rgb("youtube")
    color3 = @queue_list_view.tag_color_rgb("YOUTUBE")

    assert_equal color1, color2, "youtube should match YouTube"
    assert_equal color1, color3, "YOUTUBE should match YouTube"
  end

  def test_no_tags_shows_empty_space
    # Add queue entry without tags
    @queue_manager.add("https://example.com/video", "Test Video")

    # Refresh view
    @queue_list_view.refresh

    # Get tags_box
    row = @queue_list_view.list_widget.children.first
    event_box = row.children.first
    hbox = event_box.children.first
    vbox = hbox.children[1]
    tags_box = vbox.children[2]

    # Verify tags_box is empty (no children)
    assert_equal 0, tags_box.children.length, "Tags box should be empty"
  end
end
