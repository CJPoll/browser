require 'sqlite3'
require 'fileutils'
require 'uri'

# DownloadManager - Manages download history and cleanup
#
# Responsibilities:
# - SQLite persistence of download metadata
# - Background cleanup of entries >30 days old
# - Duplicate filename handling
# - Download state tracking (pending, active, paused, completed, failed, cancelled)
#
# Note: Actual download handling (pause/resume/cancel) is managed by WebKit download objects
# This class only tracks metadata and provides queries for the UI

class DownloadManager
  STATES = {
    pending: 'pending',
    active: 'active',
    paused: 'paused',
    completed: 'completed',
    failed: 'failed',
    cancelled: 'cancelled'
  }.freeze

  def initialize
    @data_dir = File.join(Dir.home, '.local/share/toy-browser')
    FileUtils.mkdir_p(@data_dir)

    @download_dir = File.join(Dir.home, 'Downloads')
    FileUtils.mkdir_p(@download_dir)

    @db_path = File.join(@data_dir, 'downloads.db')
    @db = SQLite3::Database.new(@db_path)
    @db.results_as_hash = true
    @db.execute("PRAGMA encoding = 'UTF-8'")

    @mutex = Mutex.new

    create_tables
    start_cleanup_thread
  end

  # Returns the download directory path
  def download_dir
    @download_dir
  end

  # Adds a new download entry
  # @param url [String] Download URL
  # @param filename [String] Original filename
  # @param total_size [Integer] Total file size in bytes (nil if unknown)
  # @return [Integer] Download ID
  def add(url, filename, total_size = nil)
    @mutex.synchronize do
      # Handle duplicate filenames
      final_filename = resolve_duplicate_filename(filename)
      filepath = File.join(@download_dir, final_filename)

      @db.execute(
        "INSERT INTO downloads (url, filename, filepath, total_size, downloaded_size, state, created_at) VALUES (?, ?, ?, ?, ?, ?, datetime('now'))",
        [url, final_filename, filepath, total_size, 0, STATES[:pending]]
      )

      @db.last_insert_row_id
    end
  end

  # Updates download progress
  # @param id [Integer] Download ID
  # @param downloaded_size [Integer] Bytes downloaded so far
  # @param state [String] Current state
  def update_progress(id, downloaded_size, state = STATES[:active])
    @mutex.synchronize do
      @db.execute(
        "UPDATE downloads SET downloaded_size = ?, state = ?, updated_at = datetime('now') WHERE id = ?",
        [downloaded_size, state, id]
      )
    end
  end

  # Updates download state
  # @param id [Integer] Download ID
  # @param state [String] New state
  def update_state(id, state)
    @mutex.synchronize do
      completed_at = (state == STATES[:completed]) ? "datetime('now')" : "NULL"
      @db.execute(
        "UPDATE downloads SET state = ?, updated_at = datetime('now'), completed_at = #{completed_at} WHERE id = ?",
        [state, id]
      )
    end
  end

  # Marks download as failed with error message
  # @param id [Integer] Download ID
  # @param error [String] Error message
  def mark_failed(id, error)
    @mutex.synchronize do
      @db.execute(
        "UPDATE downloads SET state = ?, error = ?, updated_at = datetime('now') WHERE id = ?",
        [STATES[:failed], error, id]
      )
    end
  end

  # Gets all downloads (newest first)
  # @return [Array<Hash>] Download entries
  def all
    @mutex.synchronize do
      @db.execute("SELECT * FROM downloads ORDER BY created_at DESC")
    end
  end

  # Gets active downloads (pending, active, paused)
  # @return [Array<Hash>] Active download entries
  def active
    @mutex.synchronize do
      @db.execute(
        "SELECT * FROM downloads WHERE state IN (?, ?, ?) ORDER BY created_at DESC",
        [STATES[:pending], STATES[:active], STATES[:paused]]
      )
    end
  end

  # Gets a download by ID
  # @param id [Integer] Download ID
  # @return [Hash, nil] Download entry
  def find_by_id(id)
    @mutex.synchronize do
      @db.get_first_row("SELECT * FROM downloads WHERE id = ?", [id])
    end
  end

  # Removes a download entry (does not delete file)
  # @param id [Integer] Download ID
  def remove(id)
    @mutex.synchronize do
      @db.execute("DELETE FROM downloads WHERE id = ?", [id])
    end
  end

  # Clears all download history (does not delete files)
  def clear_all
    @mutex.synchronize do
      @db.execute("DELETE FROM downloads")
    end
  end

  # Clears completed downloads from history (does not delete files)
  def clear_completed
    @mutex.synchronize do
      @db.execute("DELETE FROM downloads WHERE state = ?", [STATES[:completed]])
    end
  end

  # Stops the cleanup thread
  def stop
    @cleanup_thread&.kill
  end

  private

  def create_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL,
        filename TEXT NOT NULL,
        filepath TEXT NOT NULL,
        total_size INTEGER,
        downloaded_size INTEGER DEFAULT 0,
        state TEXT NOT NULL,
        error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        completed_at TEXT
      )
    SQL
  end

  # Starts background thread to cleanup old downloads (every 5 minutes)
  def start_cleanup_thread
    @cleanup_thread = Thread.new do
      loop do
        sleep 300  # 5 minutes
        cleanup_old_downloads
      end
    end
  end

  # Removes download entries older than 30 days
  def cleanup_old_downloads
    @mutex.synchronize do
      @db.execute("DELETE FROM downloads WHERE created_at < datetime('now', '-30 days')")
    end
  rescue => e
    warn "Download cleanup error: #{e.message}"
  end

  # Resolves duplicate filenames by appending -duplicate-N
  # @param filename [String] Original filename
  # @return [String] Unique filename
  def resolve_duplicate_filename(filename)
    filepath = File.join(@download_dir, filename)
    return filename unless File.exist?(filepath)

    # Split filename into base and extension
    ext = File.extname(filename)
    base = File.basename(filename, ext)

    # Find next available duplicate number
    counter = 1
    loop do
      new_filename = "#{base}-duplicate-#{counter}#{ext}"
      new_filepath = File.join(@download_dir, new_filename)
      return new_filename unless File.exist?(new_filepath)
      counter += 1
    end
  end
end
