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
    create_tables
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
end
