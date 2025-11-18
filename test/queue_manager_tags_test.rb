require_relative 'test_helper'

class QueueManagerTagsTest < Minitest::Test
  def setup
    # Create temporary database for each test
    # Tempfile.new creates file but we must keep reference to prevent GC deletion
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close  # Close file handle but keep @temp_db reference to prevent deletion

    @queue_manager = QueueManager.new(@temp_db_path)
  end

  def teardown
    # Clean up temporary database
    # MUST explicitly close database before deletion to release file lock
    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      begin
        db.close unless db.closed?
      rescue SQLite3::Exception => e
        # SQLite3::Exception covers:
        # - SQLite3::Exception (base class for all SQLite errors)
        # - Database already closed (db.close on closed database)
        # - I/O errors during close (rare but possible)
        # Safe to ignore - database will be GC'd eventually
      end
    end
    @queue_manager = nil

    # Delete test database file
    begin
      File.delete(@temp_db_path) if File.exist?(@temp_db_path)
    rescue Errno::EACCES, Errno::EBUSY => e
      # Database still locked - log warning but don't fail test
      warn "Warning: Could not delete #{@temp_db_path}: #{e.message}"
    end
  end

  # AC1: Schema Migration Runs Successfully
  def test_migration_v1_to_v2_creates_new_tables
    # Create a fresh temporary database to test migration from v1
    temp_v1_db = Tempfile.new(['queue_v1_test', '.db'])
    temp_v1_db_path = temp_v1_db.path
    temp_v1_db.close

    # Manually create v1 schema (queue_entries table only)
    db = SQLite3::Database.new(temp_v1_db_path)
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE queue_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT,
        favicon BLOB,
        position INTEGER NOT NULL,
        added_at INTEGER NOT NULL
      )
    SQL
    db.close

    # Instantiate QueueManager with temp v1 database (triggers migration)
    queue_manager = QueueManager.new(temp_v1_db_path)

    # Verify schema_version table exists
    result = queue_manager.instance_variable_get(:@db).get_first_value(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
    )
    assert_not_nil result, "schema_version table should exist"

    # Verify schema version is 2
    version = queue_manager.instance_variable_get(:@db).get_first_value(
      "SELECT version FROM schema_version"
    )
    assert_equal 2, version, "Schema version should be 2"

    # Verify tags table exists
    result = queue_manager.instance_variable_get(:@db).get_first_value(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tags'"
    )
    assert_not_nil result, "tags table should exist"

    # Verify queue_entry_tag_assignments table exists
    result = queue_manager.instance_variable_get(:@db).get_first_value(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='queue_entry_tag_assignments'"
    )
    assert_not_nil result, "queue_entry_tag_assignments table should exist"

    # Verify date column exists in queue_entries
    columns = queue_manager.instance_variable_get(:@db).execute(
      "PRAGMA table_info(queue_entries)"
    )
    has_date = columns.any? { |col| col['name'] == 'date' }
    assert has_date, "date column should exist in queue_entries"

    # Verify indexes exist
    indexes = queue_manager.instance_variable_get(:@db).execute(
      "SELECT name FROM sqlite_master WHERE type='index'"
    )
    index_names = indexes.map { |idx| idx['name'] }
    assert_includes index_names, 'idx_qeta_queue_entry', "idx_qeta_queue_entry index should exist"
    assert_includes index_names, 'idx_qeta_tag', "idx_qeta_tag index should exist"

    # Cleanup
    queue_manager.instance_variable_get(:@db).close
    File.delete(temp_v1_db_path) if File.exist?(temp_v1_db_path)
  end

  # AC2: Migration is Idempotent
  def test_migration_idempotent
    # Create a fresh temporary v1 database
    temp_v1_db = Tempfile.new(['queue_v1_idem_test', '.db'])
    temp_v1_db_path = temp_v1_db.path
    temp_v1_db.close

    # Manually create v1 schema
    db = SQLite3::Database.new(temp_v1_db_path)
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE queue_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT,
        favicon BLOB,
        position INTEGER NOT NULL,
        added_at INTEGER NOT NULL
      )
    SQL
    db.close

    # First migration
    queue_manager1 = QueueManager.new(temp_v1_db_path)
    # Explicitly close database before re-opening
    queue_manager1.instance_variable_get(:@db).close
    queue_manager1 = nil

    # Second migration (should be idempotent)
    queue_manager2 = QueueManager.new(temp_v1_db_path)

    # Verify schema version is still 2
    version = queue_manager2.instance_variable_get(:@db).get_first_value(
      "SELECT version FROM schema_version"
    )
    assert_equal 2, version, "Schema version should still be 2 after second migration"

    # Verify no duplicate tables
    tables = queue_manager2.instance_variable_get(:@db).execute(
      "SELECT name FROM sqlite_master WHERE type='table'"
    )
    table_names = tables.map { |t| t['name'] }

    assert_equal 1, table_names.count('schema_version'), "schema_version should appear exactly once"
    assert_equal 1, table_names.count('tags'), "tags should appear exactly once"
    assert_equal 1, table_names.count('queue_entry_tag_assignments'), "queue_entry_tag_assignments should appear exactly once"
    assert_equal 1, table_names.count('queue_entries'), "queue_entries should appear exactly once"

    # Cleanup
    queue_manager2.instance_variable_get(:@db).close
    File.delete(temp_v1_db_path) if File.exist?(temp_v1_db_path)
  end

  # AC3: Tag Creation with Case-Insensitive Uniqueness
  def test_create_or_find_tag_case_insensitive
    # Create tag "YouTube"
    tag_id_1 = @queue_manager.create_or_find_tag("YouTube")
    assert_not_nil tag_id_1, "Tag should be created"

    # Attempt to create "youtube" (lowercase) - should reuse
    tag_id_2 = @queue_manager.create_or_find_tag("youtube")
    assert_equal tag_id_1, tag_id_2, "Should return same ID for case-insensitive match"

    # Attempt to create "YOUTUBE" (uppercase) - should reuse
    tag_id_3 = @queue_manager.create_or_find_tag("YOUTUBE")
    assert_equal tag_id_1, tag_id_3, "Should return same ID for uppercase variant"

    # Verify original casing preserved
    tag = @queue_manager.find_tag_by_id(tag_id_1)
    assert_equal "YouTube", tag['name'], "Original casing should be preserved"

    # Verify only one tag exists
    all_tags = @queue_manager.all_tags
    assert_equal 1, all_tags.length, "Only one tag should exist"
    assert_equal "YouTube", all_tags[0]['name'], "Tag should have original casing"
  end

  # AC4: Tag Assignment and Unassignment
  def test_assign_and_unassign_tag
    # Add queue entry
    result = @queue_manager.add("https://example.com/video", "Example Video")
    assert_equal :added, result

    entry = @queue_manager.find_by_url("https://example.com/video")
    entry_id = entry['id']

    # Create tag
    tag_id = @queue_manager.create_or_find_tag("Tutorial")

    # Assign tag
    result = @queue_manager.assign_tag(entry_id, tag_id)
    assert_equal :assigned, result, "Tag assignment should succeed"

    # Tag appears in entry's tags
    tags = @queue_manager.tags_for_entry(entry_id)
    assert_equal 1, tags.length, "Entry should have one tag"
    assert_equal "Tutorial", tags[0]['name'], "Tag name should be Tutorial"

    # Assigning same tag again returns :already_assigned
    result2 = @queue_manager.assign_tag(entry_id, tag_id)
    assert_equal :already_assigned, result2, "Duplicate assignment should return already_assigned"

    # Unassign tag
    result3 = @queue_manager.unassign_tag(entry_id, tag_id)
    assert_equal :unassigned, result3, "Tag unassignment should succeed"

    # Tag no longer in entry's tags
    tags2 = @queue_manager.tags_for_entry(entry_id)
    assert_equal 0, tags2.length, "Entry should have no tags after unassignment"

    # Unassigning again returns :not_assigned
    result4 = @queue_manager.unassign_tag(entry_id, tag_id)
    assert_equal :not_assigned, result4, "Second unassignment should return not_assigned"
  end

  # AC5: Assign Tag by Name Creates Tag if Needed
  def test_assign_tag_by_name_creates_tag
    # Add queue entry
    @queue_manager.add("https://example.com/video", "Example Video")
    entry = @queue_manager.find_by_url("https://example.com/video")
    entry_id = entry['id']

    # Verify tag doesn't exist
    tag = @queue_manager.find_tag_by_name("NewTag")
    assert_nil tag, "Tag should not exist yet"

    # Assign tag by name (creates tag)
    result = @queue_manager.assign_tag_by_name(entry_id, "NewTag")
    assert_equal :assigned, result, "Tag should be assigned"

    # Tag was created
    tag = @queue_manager.find_tag_by_name("NewTag")
    assert_not_nil tag, "Tag should be created"
    assert_equal "NewTag", tag['name'], "Tag name should be correct"

    # Tag is assigned to entry
    tags = @queue_manager.tags_for_entry(entry_id)
    assert_equal 1, tags.length, "Entry should have one tag"
    assert_equal "NewTag", tags[0]['name'], "Tag name should match"
  end

  # AC6: Query Entries by Single Tag
  def test_entries_with_tag
    # Add 3 queue entries
    @queue_manager.add("https://example.com/video1", "Video 1")
    @queue_manager.add("https://example.com/video2", "Video 2")
    @queue_manager.add("https://example.com/video3", "Video 3")

    entry1 = @queue_manager.find_by_url("https://example.com/video1")
    entry2 = @queue_manager.find_by_url("https://example.com/video2")
    _entry3 = @queue_manager.find_by_url("https://example.com/video3")

    # Create tag and assign to entries 1 and 2
    tag_id = @queue_manager.create_or_find_tag("Tutorial")
    @queue_manager.assign_tag(entry1['id'], tag_id)
    @queue_manager.assign_tag(entry2['id'], tag_id)

    # Query entries with tag
    entries = @queue_manager.entries_with_tag(tag_id)

    # Returns 2 entries
    assert_equal 2, entries.length, "Should return 2 entries"

    # Correct entries returned
    urls = entries.map { |e| e['url'] }
    assert_includes urls, "https://example.com/video1", "Should include video1"
    assert_includes urls, "https://example.com/video2", "Should include video2"
    assert_not_includes urls, "https://example.com/video3", "Should not include video3"

    # Ordered by position
    assert_equal "https://example.com/video1", entries[0]['url'], "First entry should be video1"
    assert_equal "https://example.com/video2", entries[1]['url'], "Second entry should be video2"
  end

  # AC7: Query Entries by Multiple Tags (AND Logic)
  def test_entries_with_multiple_tags_and_logic
    # Add 3 queue entries
    @queue_manager.add("https://example.com/video1", "Video 1")
    @queue_manager.add("https://example.com/video2", "Video 2")
    @queue_manager.add("https://example.com/video3", "Video 3")

    entry1 = @queue_manager.find_by_url("https://example.com/video1")
    entry2 = @queue_manager.find_by_url("https://example.com/video2")
    entry3 = @queue_manager.find_by_url("https://example.com/video3")

    # Create tags
    youtube_id = @queue_manager.create_or_find_tag("YouTube")
    tutorial_id = @queue_manager.create_or_find_tag("Tutorial")

    # Assign tags
    # Entry 1: YouTube + Tutorial
    @queue_manager.assign_tag(entry1['id'], youtube_id)
    @queue_manager.assign_tag(entry1['id'], tutorial_id)

    # Entry 2: YouTube only
    @queue_manager.assign_tag(entry2['id'], youtube_id)

    # Entry 3: Tutorial only
    @queue_manager.assign_tag(entry3['id'], tutorial_id)

    # Query entries with BOTH tags
    entries = @queue_manager.entries_with_tags([youtube_id, tutorial_id])

    # Returns only entry 1 (has BOTH tags)
    assert_equal 1, entries.length, "Should return only entry with both tags"
    assert_equal "https://example.com/video1", entries[0]['url'], "Should be video1"

    # Querying single tag returns correct entries
    youtube_entries = @queue_manager.entries_with_tags([youtube_id])
    assert_equal 2, youtube_entries.length, "Should return 2 entries with YouTube tag"

    tutorial_entries = @queue_manager.entries_with_tags([tutorial_id])
    assert_equal 2, tutorial_entries.length, "Should return 2 entries with Tutorial tag"
  end

  # AC8: Foreign Key Cascade Deletes
  def test_cascade_delete_entry
    # Add queue entry
    @queue_manager.add("https://example.com/video", "Video")
    entry = @queue_manager.find_by_url("https://example.com/video")
    entry_id = entry['id']

    # Create and assign tag
    tag_id = @queue_manager.create_or_find_tag("Tutorial")
    @queue_manager.assign_tag(entry_id, tag_id)

    # Verify assignment exists
    tags = @queue_manager.tags_for_entry(entry_id)
    assert_equal 1, tags.length, "Entry should have tag"

    # Delete entry
    @queue_manager.remove_by_id(entry_id)

    # Entry is deleted
    entry = @queue_manager.find_by_id(entry_id)
    assert_nil entry, "Entry should be deleted"

    # Tag assignment is deleted (cascade)
    db = @queue_manager.instance_variable_get(:@db)
    count = db.get_first_value(
      "SELECT COUNT(*) FROM queue_entry_tag_assignments WHERE queue_entry_id = ?",
      [entry_id]
    )
    assert_equal 0, count, "Tag assignment should be deleted"

    # Tag still exists (not deleted)
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_not_nil tag, "Tag should still exist"
  end

  def test_cascade_delete_tag
    # Add queue entry
    @queue_manager.add("https://example.com/video", "Video")
    entry = @queue_manager.find_by_url("https://example.com/video")
    entry_id = entry['id']

    # Create and assign tag
    tag_id = @queue_manager.create_or_find_tag("Tutorial")
    @queue_manager.assign_tag(entry_id, tag_id)

    # Delete tag
    result = @queue_manager.delete_tag(tag_id)
    assert_equal :deleted, result, "Tag should be deleted"

    # Tag is deleted
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_nil tag, "Tag should be deleted"

    # Tag assignment is deleted (cascade)
    tags = @queue_manager.tags_for_entry(entry_id)
    assert_equal 0, tags.length, "Entry should have no tags"

    # Entry still exists (not deleted)
    entry = @queue_manager.find_by_id(entry_id)
    assert_not_nil entry, "Entry should still exist"
  end

  # AC9: Tag Usage Counts
  def test_tag_usage_counts
    # Add 3 queue entries
    @queue_manager.add("https://example.com/video1", "Video 1")
    @queue_manager.add("https://example.com/video2", "Video 2")
    @queue_manager.add("https://example.com/video3", "Video 3")

    entry1 = @queue_manager.find_by_url("https://example.com/video1")
    entry2 = @queue_manager.find_by_url("https://example.com/video2")
    entry3 = @queue_manager.find_by_url("https://example.com/video3")

    # Create tags and assign
    youtube_id = @queue_manager.create_or_find_tag("YouTube")
    tutorial_id = @queue_manager.create_or_find_tag("Tutorial")
    @queue_manager.create_or_find_tag("Unused")  # Create but don't assign

    # YouTube: 3 entries
    @queue_manager.assign_tag(entry1['id'], youtube_id)
    @queue_manager.assign_tag(entry2['id'], youtube_id)
    @queue_manager.assign_tag(entry3['id'], youtube_id)

    # Tutorial: 1 entry
    @queue_manager.assign_tag(entry1['id'], tutorial_id)

    # Unused: 0 entries

    # Get usage counts
    counts = @queue_manager.tag_usage_counts

    # Returns all 3 tags
    assert_equal 3, counts.length, "Should return 3 tags"

    # Correct counts
    youtube_count = counts.find { |c| c['tag_name'] == 'YouTube' }
    assert_not_nil youtube_count, "YouTube count should exist"
    assert_equal 3, youtube_count['count'], "YouTube should have 3 entries"

    tutorial_count = counts.find { |c| c['tag_name'] == 'Tutorial' }
    assert_not_nil tutorial_count, "Tutorial count should exist"
    assert_equal 1, tutorial_count['count'], "Tutorial should have 1 entry"

    unused_count = counts.find { |c| c['tag_name'] == 'Unused' }
    assert_not_nil unused_count, "Unused count should exist"
    assert_equal 0, unused_count['count'], "Unused should have 0 entries"

    # Ordered alphabetically
    names = counts.map { |c| c['tag_name'] }
    assert_equal ['Tutorial', 'Unused', 'YouTube'], names, "Tags should be ordered alphabetically"
  end

  # AC10: Edge Cases and Error Handling
  def test_edge_cases
    # 1. create_or_find_tag with nil
    result = @queue_manager.create_or_find_tag(nil)
    assert_nil result, "Should return nil for nil input"

    # 2. create_or_find_tag with empty string
    result = @queue_manager.create_or_find_tag("")
    assert_nil result, "Should return nil for empty string"

    # 3. create_or_find_tag with whitespace
    result = @queue_manager.create_or_find_tag("   ")
    assert_nil result, "Should return nil for whitespace-only string"

    # 4. create_or_find_tag strips whitespace
    tag_id = @queue_manager.create_or_find_tag("  Gaming  ")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "Gaming", tag['name'], "Tag should have whitespace stripped"

    # 5. assign_tag with invalid entry ID
    tag_id = @queue_manager.create_or_find_tag("Test")
    result = @queue_manager.assign_tag(999999, tag_id)
    assert_equal :invalid_entry, result, "Should return invalid_entry for non-existent entry"

    # 6. assign_tag with invalid tag ID
    @queue_manager.add("https://example.com", "Test")
    entry = @queue_manager.find_by_url("https://example.com")
    result = @queue_manager.assign_tag(entry['id'], 999999)
    assert_equal :invalid_tag, result, "Should return invalid_tag for non-existent tag"

    # 7. assign_tag with nil params
    result = @queue_manager.assign_tag(nil, nil)
    assert_equal :invalid_params, result, "Should return invalid_params for nil params"

    # 8. entries_with_tags with empty array
    result = @queue_manager.entries_with_tags([])
    assert_equal [], result, "Should return empty array for empty tag_ids"

    # 9. tags_for_entry with non-existent entry
    result = @queue_manager.tags_for_entry(999999)
    assert_equal [], result, "Should return empty array for non-existent entry"

    # 10. find_tag_by_name case-insensitive
    tag_id = @queue_manager.create_or_find_tag("YouTube")
    tag = @queue_manager.find_tag_by_name("youtube")
    assert_not_nil tag, "Should find tag case-insensitively"
    assert_equal tag_id, tag['id'], "Should return same tag ID"

    # 11. create_or_find_tag with 100-character limit
    # 100 characters - should succeed
    tag_100 = "a" * 100
    tag_id = @queue_manager.create_or_find_tag(tag_100)
    assert_not_nil tag_id, "Should accept 100-character tag"

    # 101 characters - should fail
    tag_101 = "a" * 101
    result = @queue_manager.create_or_find_tag(tag_101)
    assert_nil result, "Should reject 101-character tag"

    # 12. create_or_find_tag whitespace normalization
    # Internal whitespace collapsed
    tag_id = @queue_manager.create_or_find_tag("Gaming  Video")  # Double space
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "Gaming Video", tag['name'], "Should collapse double spaces"

    # Tab characters collapsed
    tag_id = @queue_manager.create_or_find_tag("Gaming\tVideo")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "Gaming Video", tag['name'], "Should collapse tabs to space"

    # Newlines collapsed
    tag_id = @queue_manager.create_or_find_tag("Gaming\nVideo")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "Gaming Video", tag['name'], "Should collapse newlines to space"

    # 13. Hash key format verification
    tag_id = @queue_manager.create_or_find_tag("Test")
    tag = @queue_manager.find_tag_by_id(tag_id)

    # Verify string keys (not symbols)
    assert tag.key?('id'), "Expected string key 'id'"
    assert tag.key?('name'), "Expected string key 'name'"
    refute tag.key?(:id), "Should not have symbol key :id"

    # Verify type conversions
    assert_kind_of Integer, tag['id'], "Tag ID should be integer"
    assert_kind_of String, tag['name'], "Tag name should be string"

    # 14. Unicode and special characters
    # Emoji
    tag_id = @queue_manager.create_or_find_tag("🎮 Gaming")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "🎮 Gaming", tag['name'], "Should support emoji"

    # Cyrillic
    tag_id = @queue_manager.create_or_find_tag("Игры")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "Игры", tag['name'], "Should support Cyrillic characters"

    # Special characters (SQL injection attempt)
    tag_id = @queue_manager.create_or_find_tag("'; DROP TABLE tags; --")
    tag = @queue_manager.find_tag_by_id(tag_id)
    assert_equal "'; DROP TABLE tags; --", tag['name'], "Should safely store special characters"

    # Verify tags table still exists (SQL injection didn't work)
    all_tags = @queue_manager.all_tags
    assert_kind_of Array, all_tags, "Tags table should still exist"
  end
end
