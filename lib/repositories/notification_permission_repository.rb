# frozen_string_literal: true

require_relative 'sqlite_connection'
require_relative '../domain/host_permission'

module Repositories
  # Hosts allowed to send web notifications.
  #
  # Keyed on hostname; callers resolve URLs to hosts before arriving here.
  class NotificationPermissionRepository
    include SqliteConnection

    DB_PATH = File.join(
      Dir.home, '.local', 'share', 'toy-browser', 'notification_permissions.db'
    )

    def initialize(db_path: DB_PATH)
      connect(db_path)
      setup_database
    end

    # @param host [String, nil] Hostname
    # @return [Boolean] True if the host may send notifications
    def exists?(host)
      return false unless host

      !@db.get_first_value(
        'SELECT id FROM notification_permissions WHERE host = ?', [host]
      ).nil?
    end

    # Grants notification permission to a host
    #
    # @param permission [Domain::HostPermission] Permission to store
    # @return [Domain::HostPermission, nil] The stored permission with its id,
    #   or nil if the host already had one
    def add(permission)
      @db.execute(
        'INSERT INTO notification_permissions (host, added_at) VALUES (?, ?)',
        [permission.host, permission.granted_at.to_i]
      )
      permission.with_id(@db.last_insert_row_id)
    rescue SQLite3::ConstraintException
      nil
    end

    # @param host [String, nil] Hostname
    # @return [Boolean] True if a permission was deleted
    def remove(host)
      return false unless host

      @db.execute('DELETE FROM notification_permissions WHERE host = ?', [host])
      @db.changes > 0
    end

    # @return [Array<Domain::HostPermission>] Every allowed host, by name
    def all
      @db.execute(
        'SELECT id, host, added_at FROM notification_permissions ORDER BY host ASC'
      ).map { |row| build_permission(row) }
    end

    private

    def setup_database
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS notification_permissions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          host TEXT NOT NULL UNIQUE,
          added_at INTEGER NOT NULL
        )
      SQL

      @db.execute 'CREATE INDEX IF NOT EXISTS idx_notification_host ON notification_permissions(host)'
    end

    def build_permission(row)
      Domain::HostPermission.new(
        id: row['id'],
        host: row['host'],
        granted_at: Time.at(row['added_at'])
      )
    end
  end
end
