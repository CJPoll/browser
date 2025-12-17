require 'sqlite3'
require 'uri'
require 'fileutils'

# Manages TLS certificate exceptions for self-signed or invalid certificates
class CertificateExceptionManager
  # Creates a new certificate exception manager
  #
  # @param db_path [String, nil] Path to database file (default: ~/.local/share/toy-browser/certificates.db)
  def initialize(db_path = nil)
    db_path ||= File.join(Dir.home, '.local/share/toy-browser/certificates.db')
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
      CREATE TABLE IF NOT EXISTS certificate_exceptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        host TEXT NOT NULL UNIQUE,
        added_at INTEGER NOT NULL
      )
    SQL

    @db.execute "CREATE INDEX IF NOT EXISTS idx_cert_host ON certificate_exceptions(host)"
  end

  # Checks if a host has a certificate exception
  #
  # @param host [String] Host to check
  # @return [Boolean] True if host has an exception
  def allowed?(host)
    return false unless host

    result = @db.get_first_value(
      "SELECT id FROM certificate_exceptions WHERE host = ?",
      [host]
    )
    !result.nil?
  end

  # Adds a certificate exception for a host
  #
  # @param host [String] Host to add exception for
  # @return [Boolean] True if added, false if already exists or invalid
  def allow(host)
    return false unless host

    begin
      @db.execute(
        "INSERT INTO certificate_exceptions (host, added_at) VALUES (?, ?)",
        [host, Time.now.to_i]
      )
      true
    rescue SQLite3::ConstraintException
      # Already exists
      false
    end
  end

  # Removes a certificate exception for a host
  #
  # @param host [String] Host to remove exception for
  # @return [Boolean] True if removed, false if not found
  def revoke(host)
    return false unless host

    @db.execute("DELETE FROM certificate_exceptions WHERE host = ?", [host])
    @db.changes > 0
  end

  # Gets all hosts with certificate exceptions
  #
  # @return [Array<Hash>] Array of {id, host, added_at} hashes
  def all
    @db.execute("SELECT id, host, added_at FROM certificate_exceptions ORDER BY host ASC")
  end
end
