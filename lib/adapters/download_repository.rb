# frozen_string_literal: true

require 'sqlite3'
require_relative '../domain/download'

# DownloadRepository handles persistence of Download domain objects to SQLite.
# It follows the Adapter pattern - receives and returns domain objects,
# handling all database interaction details internally.
class DownloadRepository
  DB_PATH = File.join(Dir.home, '.local', 'share', 'toy-browser', 'downloads.db')

  def initialize(db_path: DB_PATH)
    @db_path = db_path
    ensure_db_directory
    @db = SQLite3::Database.new(@db_path)
    @db.results_as_hash = true
    setup_database
  end

  # Save a download to the database (insert or update based on ID presence).
  # Returns the download with its ID populated.
  def save(download)
    if download.id
      update_download(download)
    else
      insert_download(download)
    end
  end

  # Find a download by ID.
  # Returns Download or nil if not found.
  def find_by_id(id)
    row = @db.get_first_row('SELECT * FROM downloads WHERE id = ?', id)
    return nil unless row

    build_download(row)
  end

  # Find all downloads, ordered by created_at descending (newest first).
  # Returns array of Download objects.
  def find_all
    rows = @db.execute('SELECT * FROM downloads ORDER BY created_at DESC')
    rows.map { |row| build_download(row) }
  end

  # Find active downloads (pending or in_progress).
  # Returns array of Download objects.
  def find_active
    rows = @db.execute(
      "SELECT * FROM downloads WHERE state IN ('pending', 'in_progress') ORDER BY created_at DESC"
    )
    rows.map { |row| build_download(row) }
  end

  # Find downloads by state.
  # Returns array of Download objects.
  def find_by_state(state)
    rows = @db.execute(
      'SELECT * FROM downloads WHERE state = ? ORDER BY created_at DESC',
      state.to_s
    )
    rows.map { |row| build_download(row) }
  end

  # Find which of the given paths already exist in the database.
  # Returns array of paths that exist.
  def find_existing_paths(paths)
    return [] if paths.empty?

    placeholders = paths.map { '?' }.join(', ')
    rows = @db.execute(
      "SELECT destination FROM downloads WHERE destination IN (#{placeholders})",
      paths
    )
    rows.map { |row| row['destination'] }
  end

  # Delete a download by ID.
  # Returns true if deleted, false if not found.
  def delete(id)
    @db.execute('DELETE FROM downloads WHERE id = ?', id)
    @db.changes > 0
  end

  # Delete all downloads.
  def delete_all
    @db.execute('DELETE FROM downloads')
  end

  # Delete downloads by state.
  def delete_by_state(state)
    @db.execute('DELETE FROM downloads WHERE state = ?', state.to_s)
  end

  # Delete downloads older than the specified number of days.
  def delete_older_than(days)
    cutoff = Time.now.to_i - (days * 24 * 3600)
    @db.execute('DELETE FROM downloads WHERE created_at < ?', cutoff)
  end

  # Close the database connection.
  def close
    @db.close if @db && !@db.closed?
  end

  private

  def ensure_db_directory
    dir = File.dirname(@db_path)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
  end

  def setup_database
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL,
        destination TEXT NOT NULL,
        state TEXT NOT NULL,
        bytes_received INTEGER NOT NULL DEFAULT 0,
        total_bytes INTEGER,
        error_message TEXT,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        completed_at INTEGER
      )
    SQL

    @db.execute "PRAGMA encoding = 'UTF-8'"
  end

  def insert_download(download)
    @db.execute(
      <<-SQL,
        INSERT INTO downloads (
          url, destination, state, bytes_received, total_bytes,
          error_message, created_at, started_at, completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        download.url,
        download.destination,
        download.state.to_s,
        download.bytes_received,
        download.total_bytes,
        download.error_message,
        to_timestamp(download.created_at),
        to_timestamp(download.started_at),
        to_timestamp(download.completed_at)
      ]
    )

    download.with_id(@db.last_insert_row_id)
  end

  def update_download(download)
    @db.execute(
      <<-SQL,
        UPDATE downloads
        SET url = ?, destination = ?, state = ?, bytes_received = ?,
            total_bytes = ?, error_message = ?, started_at = ?, completed_at = ?
        WHERE id = ?
      SQL
      [
        download.url,
        download.destination,
        download.state.to_s,
        download.bytes_received,
        download.total_bytes,
        download.error_message,
        to_timestamp(download.started_at),
        to_timestamp(download.completed_at),
        download.id
      ]
    )

    download
  end

  def build_download(row)
    Download.new(
      id: row['id'],
      url: row['url'],
      destination: row['destination'],
      state: row['state'].to_sym,
      bytes_received: row['bytes_received'] || 0,
      total_bytes: row['total_bytes'],
      error_message: row['error_message'],
      created_at: from_timestamp(row['created_at']),
      started_at: from_timestamp(row['started_at']),
      completed_at: from_timestamp(row['completed_at'])
    )
  end

  def to_timestamp(time)
    time&.to_i
  end

  def from_timestamp(timestamp)
    timestamp ? Time.at(timestamp) : nil
  end
end
