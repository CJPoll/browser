require_relative 'test_helper'

class SidebarRefreshOnTagChangeTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)

    # Add queue entry
    @queue_manager.add("https://example.com", "Test Video")
    @entry = @queue_manager.find_by_url("https://example.com")

    # Create queue list view
    @queue_list_view = create_queue_list_view(@queue_manager)

    # Track refresh calls
    @refresh_count = 0
    @queue_list_view.define_singleton_method(:refresh) do |*args|
      @refresh_count += 1
    end
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_callback_invoked_on_tag_assignment
    # Create callback that simulates sidebar refresh
    callback_invoked = false
    on_tags_changed = -> { callback_invoked = true }

    # Create dialog
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: on_tags_changed
    )

    # Assign tag via create_and_assign_tag
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "Gaming"
    dialog.send(:create_and_assign_tag)

    # Verify callback invoked
    assert callback_invoked, "Callback should be invoked after tag assignment"
  end

  def test_callback_invoked_on_tag_unassignment
    # Assign tag first
    tag_id = @queue_manager.create_or_find_tag("Gaming").id
    @queue_manager.assign_tag(@entry.id, tag_id)

    # Create callback
    callback_invoked = false
    on_tags_changed = -> { callback_invoked = true }

    # Create dialog
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: on_tags_changed
    )

    # Simulate unassigning tag via notify callback
    # Note: Cannot test actual checkbox toggle without GTK event loop
    # Test the notify_tags_changed method directly
    dialog.send(:notify_tags_changed)

    # Verify callback invoked
    assert callback_invoked, "Callback should be invoked"
  end

  def test_sidebar_mode_check_in_callback
    # Simulate BrowserWindow callback that checks sidebar mode
    sidebar_mode = :queue
    refresh_called = false

    on_tags_changed = -> {
      if sidebar_mode == :queue
        refresh_called = true
      end
    }

    # Create dialog
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: on_tags_changed
    )

    # Assign tag
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "Gaming"
    dialog.send(:create_and_assign_tag)

    # Verify refresh called when sidebar mode is :queue
    assert refresh_called, "Refresh should be called when sidebar is in queue mode"

    # Change sidebar mode and try again
    sidebar_mode = :tabs
    refresh_called = false

    new_tag_entry.text = "Tutorial"
    dialog.send(:create_and_assign_tag)

    # Verify refresh NOT called when sidebar mode is NOT :queue
    refute refresh_called, "Refresh should not be called when sidebar is not in queue mode"
  end
end
