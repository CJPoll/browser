require 'sqlite3'
require 'uri'
require 'fileutils'

# Manages media device (camera/microphone) permission whitelist
class MediaPermissionManager
  # Creates a new media permission manager
  #
  # @param db_path [String, nil] Path to database file (default: ~/.local/share/toy-browser/media_permissions.db)
  def initialize(db_path = nil)
    db_path ||= File.join(Dir.home, '.local/share/toy-browser/media_permissions.db')
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
      CREATE TABLE IF NOT EXISTS media_permissions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        host TEXT NOT NULL,
        permission_type TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        UNIQUE(host, permission_type)
      )
    SQL

    @db.execute "CREATE INDEX IF NOT EXISTS idx_media_host ON media_permissions(host)"
  end

  # Checks if a host is allowed for a specific permission type
  #
  # @param url [String] URL to check (extracts host)
  # @param permission_type [Symbol] :audio, :video, or :audio_video
  # @return [Boolean] True if host is allowed for this permission
  def allowed?(url, permission_type)
    host = extract_host(url)
    return false unless host

    type_str = permission_type.to_s
    result = @db.get_first_value(
      "SELECT id FROM media_permissions WHERE host = ? AND permission_type = ?",
      [host, type_str]
    )
    !result.nil?
  end

  # Adds a host permission to the whitelist
  #
  # @param url [String] URL to whitelist (extracts host)
  # @param permission_type [Symbol] :audio, :video, or :audio_video
  # @return [Boolean] True if added, false if already exists or invalid
  def allow(url, permission_type)
    host = extract_host(url)
    return false unless host

    type_str = permission_type.to_s
    begin
      @db.execute(
        "INSERT INTO media_permissions (host, permission_type, added_at) VALUES (?, ?, ?)",
        [host, type_str, Time.now.to_i]
      )
      true
    rescue SQLite3::ConstraintException
      # Already exists
      false
    end
  end

  # Removes a host permission from the whitelist
  #
  # @param url [String] URL to remove (extracts host)
  # @param permission_type [Symbol, nil] Permission type to remove, or nil for all
  # @return [Boolean] True if removed, false if not found or invalid
  def revoke(url, permission_type = nil)
    host = extract_host(url)
    return false unless host

    if permission_type
      @db.execute(
        "DELETE FROM media_permissions WHERE host = ? AND permission_type = ?",
        [host, permission_type.to_s]
      )
    else
      @db.execute("DELETE FROM media_permissions WHERE host = ?", [host])
    end
    @db.changes > 0
  end

  # Gets all permissions for a host
  #
  # @param url [String] URL to check (extracts host)
  # @return [Array<String>] Array of permission types for this host
  def permissions_for(url)
    host = extract_host(url)
    return [] unless host

    @db.execute(
      "SELECT permission_type FROM media_permissions WHERE host = ?",
      [host]
    ).map { |row| row['permission_type'] }
  end

  # Gets all whitelisted hosts and their permissions
  #
  # @return [Array<Hash>] Array of {id, host, permission_type, added_at} hashes
  def all
    @db.execute("SELECT id, host, permission_type, added_at FROM media_permissions ORDER BY host ASC")
  end

  private

  # Extracts host from URL
  #
  # @param url [String] URL to extract host from
  # @return [String, nil] Host or nil if invalid
  def extract_host(url)
    return nil unless url

    begin
      uri = URI.parse(url)
      uri.host
    rescue URI::InvalidURIError
      nil
    end
  end
end
