# frozen_string_literal: true

require_relative 'sqlite_connection'
require_relative '../domain/host_permission'

module Repositories
  # Hosts allowed to use the camera and/or microphone.
  #
  # Unlike the other permission stores this one is keyed on (host,
  # permission_type): a site allowed to use the microphone is not thereby
  # allowed to use the camera, so a host may hold several rows.
  class MediaPermissionRepository
    include SqliteConnection

    DB_PATH = File.join(
      Dir.home, '.local', 'share', 'toy-browser', 'media_permissions.db'
    )

    def initialize(db_path: DB_PATH)
      connect(db_path)
      setup_database
    end

    # @param host [String, nil] Hostname
    # @param permission_type [Symbol, String, nil] Media permission type
    # @return [Boolean] True if the host holds that permission
    def exists?(host, permission_type)
      return false unless host && permission_type

      !@db.get_first_value(
        'SELECT id FROM media_permissions WHERE host = ? AND permission_type = ?',
        [host, permission_type.to_s]
      ).nil?
    end

    # Grants a media permission to a host
    #
    # @param permission [Domain::HostPermission] Permission to store
    # @return [Domain::HostPermission, nil] The stored permission with its id,
    #   or nil if the host already held it
    def add(permission)
      @db.execute(
        'INSERT INTO media_permissions (host, permission_type, added_at) VALUES (?, ?, ?)',
        [permission.host, permission.permission_type.to_s, permission.granted_at.to_i]
      )
      permission.with_id(@db.last_insert_row_id)
    rescue SQLite3::ConstraintException
      nil
    end

    # Revokes one permission type, or every permission the host holds
    #
    # @param host [String, nil] Hostname
    # @param permission_type [Symbol, String, nil] Type to revoke, or nil for all
    # @return [Boolean] True if anything was deleted
    def remove(host, permission_type = nil)
      return false unless host

      if permission_type
        @db.execute(
          'DELETE FROM media_permissions WHERE host = ? AND permission_type = ?',
          [host, permission_type.to_s]
        )
      else
        @db.execute('DELETE FROM media_permissions WHERE host = ?', [host])
      end

      @db.changes > 0
    end

    # @return [Array<Domain::HostPermission>] Every granted permission, by host
    def all
      @db.execute(
        'SELECT id, host, permission_type, added_at FROM media_permissions ORDER BY host ASC'
      ).map { |row| build_permission(row) }
    end

    private

    def setup_database
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS media_permissions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          host TEXT NOT NULL,
          permission_type TEXT NOT NULL,
          added_at INTEGER NOT NULL,
          UNIQUE(host, permission_type)
        )
      SQL

      @db.execute 'CREATE INDEX IF NOT EXISTS idx_media_host ON media_permissions(host)'
    end

    def build_permission(row)
      Domain::HostPermission.new(
        id: row['id'],
        host: row['host'],
        permission_type: row['permission_type'],
        granted_at: Time.at(row['added_at'])
      )
    end
  end
end
