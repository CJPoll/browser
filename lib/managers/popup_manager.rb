require 'sqlite3'
require 'fileutils'
require_relative '../domain/url_host'

# Manages popup exceptions (whitelist) for browser popups
class PopupManager
  # Creates a new popup manager
  #
  # @param db_path [String, nil] Path to database file (default: ~/.local/share/toy-browser/popups.db)
  def initialize(db_path = nil)
    db_path ||= File.join(Dir.home, '.local/share/toy-browser/popups.db')
    FileUtils.mkdir_p(File.dirname(db_path))

    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    @db.execute("PRAGMA encoding = 'UTF-8'")
    create_tables
  end

  # Creates database tables if they don't exist
  #
  # @return [void]
  def create_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS popup_exceptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        host TEXT NOT NULL UNIQUE,
        added_at INTEGER NOT NULL
      )
    SQL

    @db.execute "CREATE INDEX IF NOT EXISTS idx_popup_host ON popup_exceptions(host)"
  end

  # Checks if a host is whitelisted for popups
  #
  # @param url [String] URL to check (extracts host)
  # @return [Boolean] True if host is whitelisted
  def allowed?(url)
    host = Domain::UrlHost.host(url)
    return false unless host

    result = @db.get_first_value(
      "SELECT id FROM popup_exceptions WHERE host = ?",
      [host]
    )
    !result.nil?
  end

  # Adds a host to the popup whitelist
  #
  # @param url [String] URL to whitelist (extracts host)
  # @return [Boolean] True if added, false if already exists or invalid
  def allow(url)
    host = Domain::UrlHost.host(url)
    return false unless host

    begin
      @db.execute(
        "INSERT INTO popup_exceptions (host, added_at) VALUES (?, ?)",
        [host, Time.now.to_i]
      )
      true
    rescue SQLite3::ConstraintException
      # Already exists
      false
    end
  end

  # Removes a host from the popup whitelist
  #
  # @param url [String] URL to remove (extracts host)
  # @return [Boolean] True if removed, false if not found or invalid
  def block(url)
    host = Domain::UrlHost.host(url)
    return false unless host

    @db.execute("DELETE FROM popup_exceptions WHERE host = ?", [host])
    @db.changes > 0
  end

  # Gets all whitelisted hosts
  #
  # @return [Array<Hash>] Array of {id, host, added_at} hashes
  def all
    @db.execute("SELECT id, host, added_at FROM popup_exceptions ORDER BY host ASC")
  end
end
