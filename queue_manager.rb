require 'sqlite3'
require 'uri'
require 'fileutils'

class QueueManager
  def initialize(db_path = nil)
    db_path ||= File.join(Dir.home, '.local/share/toy-browser/queue.db')
    FileUtils.mkdir_p(File.dirname(db_path))

    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    # Force UTF-8 encoding for text columns
    @db.execute("PRAGMA encoding = 'UTF-8'")
    # Enable foreign key constraints
    @db.execute("PRAGMA foreign_keys = ON")
    create_tables
    migrate_schema
  end

  def create_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS queue_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT,
        favicon BLOB,
        position INTEGER NOT NULL,
        added_at INTEGER NOT NULL
      )
    SQL

    @db.execute "CREATE INDEX IF NOT EXISTS idx_queue_position ON queue_entries(position)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_queue_url ON queue_entries(url)"
  end

  # Add a URL to the queue. Returns :added or :already_exists
  def add(url, title = nil, favicon_data = nil)
    return :invalid_url unless url

    begin
      uri = URI.parse(url)
      return :invalid_url unless uri.scheme =~ /^https?$/
    rescue URI::InvalidURIError
      return :invalid_url
    end

    # Check if URL already exists
    existing = @db.get_first_value("SELECT id FROM queue_entries WHERE url = ?", [url])
    return :already_exists if existing

    now = Time.now.to_i

    @db.transaction do
      # Get the next position (max + 1)
      max_position = @db.get_first_value("SELECT MAX(position) FROM queue_entries") || 0
      next_position = max_position + 1

      @db.execute(
        "INSERT INTO queue_entries (url, title, favicon, position, added_at) VALUES (?, ?, ?, ?, ?)",
        [url, title, favicon_data, next_position, now]
      )
    end

    :added
  end

  # Get all queue entries in order
  def all
    @db.execute(<<-SQL)
      SELECT id, url, title, favicon, position, added_at
      FROM queue_entries
      ORDER BY position ASC
    SQL
  end

  # Get the first entry in the queue
  def first
    @db.get_first_row(<<-SQL)
      SELECT id, url, title, favicon, position, added_at
      FROM queue_entries
      ORDER BY position ASC
      LIMIT 1
    SQL
  end

  # Get entry by URL
  def find_by_url(url)
    @db.get_first_row(
      "SELECT id, url, title, favicon, position, added_at FROM queue_entries WHERE url = ?",
      [url]
    )
  end

  # Get entry by ID
  def find_by_id(id)
    @db.get_first_row(
      "SELECT id, url, title, favicon, position, added_at FROM queue_entries WHERE id = ?",
      [id]
    )
  end

  # Remove an entry by URL and return the next entry
  def remove_by_url(url)
    entry = find_by_url(url)
    return nil unless entry

    remove_by_id(entry['id'])
  end

  # Remove an entry by ID and return the next entry
  def remove_by_id(id)
    entry = find_by_id(id)
    return nil unless entry

    current_position = entry['position']

    @db.transaction do
      # Delete the entry
      @db.execute("DELETE FROM queue_entries WHERE id = ?", [id])

      # Renumber positions to close the gap
      @db.execute(
        "UPDATE queue_entries SET position = position - 1 WHERE position > ?",
        [current_position]
      )
    end

    # Return the next entry (which now has the same position as the deleted one)
    @db.get_first_row(
      "SELECT id, url, title, favicon, position, added_at FROM queue_entries WHERE position = ?",
      [current_position]
    )
  end

  # Move an entry to a new position
  def move(id, new_position)
    entry = find_by_id(id)
    return false unless entry

    old_position = entry['position']
    return true if old_position == new_position # No change needed

    max_position = @db.get_first_value("SELECT MAX(position) FROM queue_entries") || 0
    new_position = [[new_position, 1].max, max_position].min # Clamp to valid range

    @db.transaction do
      if new_position < old_position
        # Moving up: shift entries down
        @db.execute(
          "UPDATE queue_entries SET position = position + 1 WHERE position >= ? AND position < ?",
          [new_position, old_position]
        )
      else
        # Moving down: shift entries up
        @db.execute(
          "UPDATE queue_entries SET position = position - 1 WHERE position > ? AND position <= ?",
          [old_position, new_position]
        )
      end

      # Update the moved entry's position
      @db.execute("UPDATE queue_entries SET position = ? WHERE id = ?", [new_position, id])
    end

    true
  end

  # Move an entry up one position
  def move_up(id)
    entry = find_by_id(id)
    return false unless entry
    return false if entry['position'] <= 1 # Already at top

    move(id, entry['position'] - 1)
  end

  # Move an entry down one position
  def move_down(id)
    entry = find_by_id(id)
    return false unless entry

    max_position = @db.get_first_value("SELECT MAX(position) FROM queue_entries") || 0
    return false if entry['position'] >= max_position # Already at bottom

    move(id, entry['position'] + 1)
  end

  # Update favicon for a URL
  def update_favicon(url, favicon_data)
    return unless url && favicon_data

    @db.execute(
      "UPDATE queue_entries SET favicon = ? WHERE url = ?",
      [favicon_data, url]
    )
  end

  # Update title for a URL
  def update_title(url, title)
    return unless url && title

    @db.execute(
      "UPDATE queue_entries SET title = ? WHERE url = ?",
      [title, url]
    )
  end

  # Get count of entries
  def count
    @db.get_first_value("SELECT COUNT(*) FROM queue_entries") || 0
  end

  # Clear all entries
  def clear_all
    @db.execute("DELETE FROM queue_entries")
  end

  private

  # Check current database schema version
  def current_schema_version
    # Check if schema_version table exists
    result = @db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
    )

    return 1 if result.nil?  # No schema_version table = v1

    # Get version from table (empty table is treated as v1 - invalid state but recoverable)
    @db.get_first_value("SELECT version FROM schema_version") || 1
  end

  # Migrate database schema to latest version
  def migrate_schema
    # Verify foreign key support is enabled
    fk_enabled = @db.get_first_value("PRAGMA foreign_keys")
    if fk_enabled != 1
      raise RuntimeError, "SQLite foreign key support is not enabled. This requires SQLite 3.6.19 or later. Please upgrade your SQLite installation."
    end

    version = current_schema_version

    case version
    when 1
      migrate_v1_to_v2
    # Future migrations will add more cases
    # when 2
    #   migrate_v2_to_v3
    end
  end

  # Migrate from schema v1 to v2
  def migrate_v1_to_v2
    @db.transaction do
      # Create schema_version table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER PRIMARY KEY
        )
      SQL

      # Create tags table with length validation
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS tags (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK(length(name) <= 100)
        )
      SQL

      # Create tag assignments table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS queue_entry_tag_assignments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          queue_entry_id INTEGER NOT NULL,
          tag_id INTEGER NOT NULL,
          FOREIGN KEY (queue_entry_id) REFERENCES queue_entries(id) ON DELETE CASCADE,
          FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE,
          UNIQUE (queue_entry_id, tag_id)
        )
      SQL

      # Create indexes
      @db.execute <<-SQL
        CREATE INDEX IF NOT EXISTS idx_qeta_queue_entry
          ON queue_entry_tag_assignments(queue_entry_id)
      SQL

      @db.execute <<-SQL
        CREATE INDEX IF NOT EXISTS idx_qeta_tag
          ON queue_entry_tag_assignments(tag_id)
      SQL

      # Add date column to queue_entries
      # Check if column exists first (migration might be retried)
      columns = @db.execute("PRAGMA table_info(queue_entries)")
      has_date_column = columns.any? { |col| col['name'] == 'date' }

      unless has_date_column
        @db.execute "ALTER TABLE queue_entries ADD COLUMN date INTEGER"
      end

      # Set schema version to 2
      @db.execute "INSERT OR REPLACE INTO schema_version (version) VALUES (2)"
    end
  rescue SQLite3::Exception => e
    # Log error to stderr with context for user
    $stderr.puts "ERROR: Database migration v1→v2 failed: #{e.message}"
    $stderr.puts "Database may be in inconsistent state. Please restore from backup at ~/.local/share/toy-browser/queue.db"
    raise  # Re-raise to prevent browser startup with broken schema
  end

  public

  # Create a new tag or return existing tag with same name (case-insensitive)
  #
  # === Parameters
  # * +tag_name+ (String) - Tag name to create/find
  #
  # === Returns
  # * Integer - Tag ID if successful
  # * nil - If tag_name is nil, empty string, whitespace-only, or exceeds 100 characters
  #
  # === Examples
  #   tag_id = queue_manager.create_or_find_tag("YouTube")      # Creates tag
  #   tag_id = queue_manager.create_or_find_tag("youtube")       # Returns same ID (case-insensitive)
  #   tag_id = queue_manager.create_or_find_tag("  Gaming  ")    # Strips whitespace
  #   result = queue_manager.create_or_find_tag("a" * 101)       # Returns nil (exceeds 100 chars)
  def create_or_find_tag(tag_name)
    return nil if tag_name.nil? || tag_name.strip.empty?

    # Normalize whitespace: strip leading/trailing, collapse internal to single spaces
    tag_name = tag_name.strip.gsub(/\s+/, ' ')

    # Validate length (application-level check before database constraint)
    return nil if tag_name.length > 100

    # Check for existing tag (case-insensitive)
    existing = @db.get_first_row(
      "SELECT id, name FROM tags WHERE name = ? COLLATE NOCASE",
      [tag_name]
    )

    return existing['id'] if existing

    # Create new tag (database CHECK constraint also enforces length)
    @db.execute("INSERT INTO tags (name) VALUES (?)", [tag_name])
    @db.last_insert_row_id
  end

  # Find tag by name (case-insensitive lookup)
  #
  # === Parameters
  # * +tag_name+ (String) - Tag name to search for
  #
  # === Returns
  # * Hash - Tag record with keys 'id' and 'name'
  # * nil - If tag not found or tag_name is invalid
  #
  # === Examples
  #   tag = queue_manager.find_tag_by_name("YouTube")       # Returns tag hash
  #   tag = queue_manager.find_tag_by_name("youtube")        # Case-insensitive
  #   tag = queue_manager.find_tag_by_name("NonExistent")    # Returns nil
  def find_tag_by_name(tag_name)
    return nil if tag_name.nil?

    # Normalize whitespace first (BEFORE empty check)
    tag_name = tag_name.strip.gsub(/\s+/, ' ')

    # Check if empty AFTER normalization
    return nil if tag_name.empty?

    @db.get_first_row(
      "SELECT id, name FROM tags WHERE name = ? COLLATE NOCASE",
      [tag_name]
    )
  end

  # Find tag by ID
  #
  # === Parameters
  # * +tag_id+ (Integer) - Tag ID
  #
  # === Returns
  # * Hash - Tag record with keys 'id' and 'name'
  # * nil - If tag not found or tag_id is invalid
  #
  # === Examples
  #   tag = queue_manager.find_tag_by_id(42)       # Returns tag hash or nil
  def find_tag_by_id(tag_id)
    return nil if tag_id.nil?

    # No type validation - let SQLite handle it
    # Non-integer values will simply not match any rows (return nil)
    # Negative or zero values are valid queries (just won't match)
    @db.get_first_row(
      "SELECT id, name FROM tags WHERE id = ?",
      [tag_id]
    )
  end

  # Get all tags ordered alphabetically by name
  #
  # === Returns
  # * Array<Hash> - Array of tag records, each with keys 'id' and 'name'
  # * Empty array if no tags exist
  #
  # === Examples
  #   tags = queue_manager.all_tags    # [{ 'id' => 1, 'name' => 'Gaming' }, ...]
  def all_tags
    @db.execute(
      "SELECT id, name FROM tags ORDER BY name COLLATE NOCASE ASC"
    )
  end

  # Assign a tag to a queue entry
  #
  # === Parameters
  # * +entry_id+ (Integer) - Queue entry ID
  # * +tag_id+ (Integer) - Tag ID
  #
  # === Returns
  # * :assigned - Tag successfully assigned
  # * :already_assigned - Tag was already assigned to this entry (no-op)
  # * :invalid_entry - Entry ID does not exist
  # * :invalid_tag - Tag ID does not exist
  # * :invalid_params - One or both IDs are nil
  #
  # === Examples
  #   result = queue_manager.assign_tag(5, 3)      # :assigned
  #   result = queue_manager.assign_tag(5, 3)      # :already_assigned (second call)
  #   result = queue_manager.assign_tag(999, 3)    # :invalid_entry
  def assign_tag(entry_id, tag_id)
    return :invalid_params if entry_id.nil? || tag_id.nil?

    # Verify entry exists
    entry = find_by_id(entry_id)
    return :invalid_entry unless entry

    # Verify tag exists
    tag = find_tag_by_id(tag_id)
    return :invalid_tag unless tag

    # Check if already assigned
    existing = @db.get_first_value(
      "SELECT id FROM queue_entry_tag_assignments WHERE queue_entry_id = ? AND tag_id = ?",
      [entry_id, tag_id]
    )

    return :already_assigned if existing

    # Create assignment
    @db.execute(
      "INSERT INTO queue_entry_tag_assignments (queue_entry_id, tag_id) VALUES (?, ?)",
      [entry_id, tag_id]
    )

    :assigned
  end

  # Remove tag assignment from a queue entry
  #
  # === Parameters
  # * +entry_id+ (Integer) - Queue entry ID
  # * +tag_id+ (Integer) - Tag ID
  #
  # === Returns
  # * :unassigned - Tag successfully removed
  # * :not_assigned - Tag was not assigned to this entry (no-op)
  # * :invalid_params - One or both IDs are nil
  #
  # === Examples
  #   result = queue_manager.unassign_tag(5, 3)    # :unassigned
  #   result = queue_manager.unassign_tag(5, 3)    # :not_assigned (second call)
  def unassign_tag(entry_id, tag_id)
    return :invalid_params if entry_id.nil? || tag_id.nil?

    @db.execute(
      "DELETE FROM queue_entry_tag_assignments WHERE queue_entry_id = ? AND tag_id = ?",
      [entry_id, tag_id]
    )

    # Check if any rows were deleted
    @db.changes > 0 ? :unassigned : :not_assigned
  end

  # Assign tag by name (creates tag if it doesn't exist)
  #
  # === Parameters
  # * +entry_id+ (Integer) - Queue entry ID
  # * +tag_name+ (String) - Tag name
  #
  # === Returns
  # * :assigned - Tag successfully assigned (existing or newly created)
  # * :already_assigned - Tag was already assigned
  # * :invalid_entry - Entry ID does not exist
  # * :invalid_params - entry_id is nil or tag_name is empty
  #
  # === Examples
  #   result = queue_manager.assign_tag_by_name(5, "YouTube")    # :assigned
  def assign_tag_by_name(entry_id, tag_name)
    return :invalid_params if entry_id.nil?

    tag_id = create_or_find_tag(tag_name)
    return :invalid_params if tag_id.nil?  # tag_name was empty/invalid

    assign_tag(entry_id, tag_id)
  end

  # Remove tag assignment by name
  #
  # === Parameters
  # * +entry_id+ (Integer) - Queue entry ID
  # * +tag_name+ (String) - Tag name
  #
  # === Returns
  # * :unassigned - Tag successfully removed
  # * :not_assigned - Tag was not assigned (or tag doesn't exist)
  # * :invalid_params - entry_id is nil or tag_name is empty
  #
  # === Examples
  #   result = queue_manager.unassign_tag_by_name(5, "YouTube")    # :unassigned
  def unassign_tag_by_name(entry_id, tag_name)
    return :invalid_params if entry_id.nil? || tag_name.nil? || tag_name.strip.empty?

    tag = find_tag_by_name(tag_name)
    return :not_assigned unless tag

    unassign_tag(entry_id, tag['id'])
  end

  # Get all tags assigned to a queue entry
  #
  # === Parameters
  # * +entry_id+ (Integer) - Queue entry ID
  #
  # === Returns
  # * Array<Hash> - Array of tag records, each with keys 'id' and 'name', sorted alphabetically
  # * Empty array if entry has no tags or entry doesn't exist
  #
  # === Examples
  #   tags = queue_manager.tags_for_entry(5)    # [{ 'id' => 1, 'name' => 'Gaming' }, ...]
  def tags_for_entry(entry_id)
    return [] if entry_id.nil?

    @db.execute(<<-SQL, [entry_id])
      SELECT t.id, t.name
      FROM tags t
      INNER JOIN queue_entry_tag_assignments qeta ON t.id = qeta.tag_id
      WHERE qeta.queue_entry_id = ?
      ORDER BY t.name COLLATE NOCASE ASC
    SQL
  end

  # Get all queue entries with a specific tag
  #
  # === Parameters
  # * +tag_id+ (Integer) - Tag ID
  #
  # === Returns
  # * Array<Hash> - Array of queue entry records (full entry data), ordered by position
  # * Empty array if no entries have this tag or tag doesn't exist
  #
  # === Examples
  #   entries = queue_manager.entries_with_tag(3)    # [{ 'id' => 1, 'url' => '...', ... }, ...]
  def entries_with_tag(tag_id)
    return [] if tag_id.nil?

    @db.execute(<<-SQL, [tag_id])
      SELECT qe.id, qe.url, qe.title, qe.favicon, qe.position, qe.added_at, qe.date
      FROM queue_entries qe
      INNER JOIN queue_entry_tag_assignments qeta ON qe.id = qeta.queue_entry_id
      WHERE qeta.tag_id = ?
      ORDER BY qe.position ASC
    SQL
  end

  # Get queue entries that have ALL specified tags (AND logic)
  #
  # === Parameters
  # * +tag_ids+ (Array<Integer>) - Array of tag IDs
  #
  # === Returns
  # * Array<Hash> - Array of queue entry records (full entry data), ordered by position
  # * Empty array if no entries match or tag_ids is empty
  #
  # === Examples
  #   entries = queue_manager.entries_with_tags([1, 3])    # Entries with BOTH tags 1 and 3
  def entries_with_tags(tag_ids)
    return [] if tag_ids.nil? || tag_ids.empty?

    # Use HAVING COUNT to ensure entry has ALL specified tags
    placeholders = tag_ids.map { '?' }.join(',')

    @db.execute(<<-SQL, tag_ids)
      SELECT qe.id, qe.url, qe.title, qe.favicon, qe.position, qe.added_at, qe.date
      FROM queue_entries qe
      INNER JOIN queue_entry_tag_assignments qeta ON qe.id = qeta.queue_entry_id
      WHERE qeta.tag_id IN (#{placeholders})
      GROUP BY qe.id
      HAVING COUNT(DISTINCT qeta.tag_id) = #{tag_ids.length}
      ORDER BY qe.position ASC
    SQL
  end

  # Get usage count for each tag (how many entries have each tag)
  #
  # === Returns
  # * Array<Hash> - Array of hashes with keys 'tag_id', 'tag_name', 'count', ordered by tag name
  #
  # === Examples
  #   counts = queue_manager.tag_usage_counts
  #   # [{ 'tag_id' => 1, 'tag_name' => 'Gaming', 'count' => 8 }, ...]
  def tag_usage_counts
    @db.execute(<<-SQL)
      SELECT
        t.id AS tag_id,
        t.name AS tag_name,
        COUNT(qeta.queue_entry_id) AS count
      FROM tags t
      LEFT JOIN queue_entry_tag_assignments qeta ON t.id = qeta.tag_id
      GROUP BY t.id, t.name
      ORDER BY t.name COLLATE NOCASE ASC
    SQL
  end

  # Delete a tag and all its assignments
  #
  # === Parameters
  # * +tag_id+ (Integer) - Tag ID to delete
  #
  # === Returns
  # * :deleted - Tag successfully deleted
  # * :not_found - Tag ID does not exist
  # * :invalid_params - tag_id is nil
  #
  # === Examples
  #   result = queue_manager.delete_tag(3)    # :deleted
  #   result = queue_manager.delete_tag(999)  # :not_found
  def delete_tag(tag_id)
    return :invalid_params if tag_id.nil?

    @db.execute("DELETE FROM tags WHERE id = ?", [tag_id])

    @db.changes > 0 ? :deleted : :not_found
  end
end
