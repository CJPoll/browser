require_relative 'test_helper'

class TagEditDialogTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)

    # Add queue entry
    @queue_manager.add("https://example.com", "Test Page")
    @entry = @queue_manager.find_by_url("https://example.com")

    # Create tags
    @tag1_id = @queue_manager.create_or_find_tag("Tag1").id
    @tag2_id = @queue_manager.create_or_find_tag("Tag2").id
    @tag3_id = @queue_manager.create_or_find_tag("Tag3").id

    # Assign Tag1 only
    @queue_manager.assign_tag(@entry.id, @tag1_id)

    # Track callback invocations
    @callback_count = 0
    @on_tags_changed = -> { @callback_count += 1 }
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_dialog_initialization
    # Note: Cannot test actual GTK dialog display without X server
    # This test verifies data initialization only

    dialog = TagEditDialog.new(
      nil,  # parent_window (nil for testing)
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    # Verify assigned_tag_ids initialized correctly
    assigned_ids = dialog.instance_variable_get(:@assigned_tag_ids)
    assert_equal [@tag1_id], assigned_ids, "Should have Tag1 assigned"
  end

  def test_create_and_assign_tag_new_tag
    # Create dialog
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    # Set new tag entry text
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "NewTag"

    # Simulate create button click
    dialog.send(:create_and_assign_tag)

    # Verify tag created
    tag = @queue_manager.find_tag_by_name("NewTag")
    assert_not_nil tag, "Tag should be created"

    # Verify tag assigned
    tags = @queue_manager.tags_for_entry(@entry.id)
    tag_names = tags.map { |t| t.name }
    assert_includes tag_names, "NewTag", "Tag should be assigned to entry"

    # Verify callback invoked
    assert_equal 1, @callback_count, "Callback should be invoked once"
  end

  def test_create_and_assign_tag_empty_name
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    # Set empty tag entry text (whitespace only)
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "   "

    # Simulate create button click
    dialog.send(:create_and_assign_tag)

    # Verify no tag created
    tags = @queue_manager.all_tags
    assert_equal 3, tags.length, "Should still have only 3 tags"

    # Verify callback NOT invoked
    assert_equal 0, @callback_count, "Callback should not be invoked"
  end

  def test_create_and_assign_tag_already_exists
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    # Set existing tag name (case-insensitive match)
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "tag1"  # Already exists as "Tag1"

    # Simulate create button click
    dialog.send(:create_and_assign_tag)

    # Verify no duplicate tag created
    tags = @queue_manager.all_tags
    assert_equal 3, tags.length, "Should still have only 3 tags"

    # Verify entry text cleared
    assert_equal "", new_tag_entry.text, "Entry should be cleared"
  end

  def test_filter_tag_list
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    # Get tag list box
    tag_list_box = dialog.instance_variable_get(:@tag_list_box)

    # Initially all rows visible (using @filter_visible for testability without display)
    visible_count = tag_list_box.children.count { |row| row.instance_variable_get(:@filter_visible) }
    assert_equal 3, visible_count, "All 3 tags should be visible"

    # Filter to "Tag1"
    dialog.send(:filter_tag_list, "Tag1")

    # Only 1 row visible
    visible_count = tag_list_box.children.count { |row| row.instance_variable_get(:@filter_visible) }
    assert_equal 1, visible_count, "Only 1 tag should be visible"

    # Clear filter (empty string)
    dialog.send(:filter_tag_list, "")

    # All rows visible again
    visible_count = tag_list_box.children.count { |row| row.instance_variable_get(:@filter_visible) }
    assert_equal 3, visible_count, "All 3 tags should be visible"
  end

  def test_filter_tag_list_whitespace_only
    # Addresses Gap #9 - whitespace-only search should show all tags
    dialog = TagEditDialog.new(
      nil,
      @entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed
    )

    tag_list_box = dialog.instance_variable_get(:@tag_list_box)

    # Filter with whitespace-only string
    dialog.send(:filter_tag_list, "   ")

    # All rows should be visible (whitespace stripped to empty string)
    # Using @filter_visible for testability without display
    visible_count = tag_list_box.children.count { |row| row.instance_variable_get(:@filter_visible) }
    assert_equal 3, visible_count, "All tags should be visible for whitespace-only search"
  end

  def test_dialog_with_nonexistent_entry_id
    # Addresses Gap #8 - deleted entry handling
    # Create entry hash with non-existent ID
    fake_entry = Domain::QueueEntry.new(
      id: 99999,
      url: 'https://example.com',
      title: 'Non-existent Entry',
      added_at: Time.at(1_700_000_000)
    )

    # Collect errors instead of showing a blocking modal dialog
    reported_errors = []

    # Dialog should initialize without error
    dialog = TagEditDialog.new(
      nil,
      fake_entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed,
      on_error: ->(message) { reported_errors << message }
    )

    # tags_for_entry returns empty array for non-existent ID
    assigned_ids = dialog.instance_variable_get(:@assigned_tag_ids)
    assert_equal [], assigned_ids, "Should have no assigned tags"

    # Attempting to assign tag should fail gracefully
    new_tag_entry = dialog.instance_variable_get(:@new_tag_entry)
    new_tag_entry.text = "NewTag"

    # create_and_assign_tag should handle :invalid_entry result
    dialog.send(:create_and_assign_tag)

    # Error is reported through the on_error callback (no modal in tests)
    assert_equal ["Queue entry no longer exists"], reported_errors

    # Callback should not be invoked on :invalid_entry error
    assert_equal 0, @callback_count, "Callback should not be invoked on error"
  end

  # --- Checkbox toggling ---
  #
  # GTK signal emission does not reach Ruby handlers under minitest, so the
  # checkbox cannot be ticked. Its handler is a one-line call to `toggle_tag`,
  # which is what these tests drive.

  def test_toggle_tag_on_assigns_and_announces_the_change
    dialog = build_dialog
    tag2 = @queue_manager.find_tag_by_id(@tag2_id)

    dialog.toggle_tag(tag2, true)

    assert_equal [@tag1_id, @tag2_id].sort,
                 @queue_manager.tags_for_entry(@entry.id).map(&:id).sort
    assert_equal 1, @callback_count
  end

  def test_toggle_tag_off_unassigns_and_announces_the_change
    dialog = build_dialog
    tag1 = @queue_manager.find_tag_by_id(@tag1_id)

    dialog.toggle_tag(tag1, false)

    assert_equal [], @queue_manager.tags_for_entry(@entry.id).map(&:id)
    assert_equal 1, @callback_count
  end

  def test_toggling_a_tag_that_is_already_assigned_is_not_an_error
    dialog = build_dialog
    tag1 = @queue_manager.find_tag_by_id(@tag1_id)

    dialog.toggle_tag(tag1, true)

    assert_empty @reported_errors
    assert_equal 0, @callback_count, "Nothing changed, so nothing is announced"
  end

  def test_toggling_a_tag_on_a_deleted_entry_reports_the_error
    fake_entry = Domain::QueueEntry.new(
      id: 99_999,
      url: 'https://example.com',
      added_at: Time.at(1_700_000_000)
    )
    dialog = build_dialog(entry: fake_entry)
    tag1 = @queue_manager.find_tag_by_id(@tag1_id)

    dialog.toggle_tag(tag1, true)

    assert_equal ["Queue entry no longer exists"], @reported_errors
  end

  # --- Bucket rules ---

  # ADR 001: a UI component may not hold a manager, repository or adapter.
  def test_holds_no_manager_or_repository
    dialog = build_dialog

    collaborators = dialog.instance_variables.map { |name| dialog.instance_variable_get(name) }

    assert(collaborators.none? { |value| value.class.name.to_s =~ /Manager|Repository|Adapter/ })
  end

  private

  # Builds a dialog wired to the queue manager the way BrowserWindow does,
  # collecting errors instead of opening a modal that would block the run.
  def build_dialog(entry: @entry)
    @reported_errors = []

    TagEditDialog.new(
      nil,
      entry,
      **tag_edit_dialog_callbacks(@queue_manager),
      on_tags_changed: @on_tags_changed,
      on_error: ->(message) { @reported_errors << message }
    )
  end
end
