# frozen_string_literal: true

require 'monitor'
require 'sqlite3'
require_relative 'sqlite_connection'

module Repositories
  # The `queue.db` connection, shared by `QueueRepository` and `TagRepository`.
  #
  # Two repositories rather than one because entries and tags are separate
  # concerns, but *one* connection because they are one file, one transaction
  # scope, and one schema history: the v1 -> v2 migration creates the tag
  # tables and adds `queue_entries.date` in a single transaction, so no single
  # repository can own it. Schema ownership therefore sits here; every query
  # against an individual table still lives in that table's repository.
  #
  # The queue is written from the metadata worker's background thread as well
  # as the GTK main loop, so access is serialized through a reentrant
  # `Monitor` -- reentrant so a repository can call `synchronize` inside a
  # block that is already synchronized (reading `changes` right after the
  # `DELETE` that produced it, for instance).
  class QueueDatabase
    include SqliteConnection

    DB_PATH = File.join(Dir.home, '.local', 'share', 'toy-browser', 'queue.db')

    # Schema this class migrates to. v1 is the original entries-only database;
    # v2 adds tags, tag assignments and the publication-date column.
    SCHEMA_VERSION = 2

    # @param db_path [String] Path to the SQLite file
    def initialize(db_path: DB_PATH)
      connect(db_path)
      @db.execute('PRAGMA foreign_keys = ON')
      @monitor = Monitor.new
      create_tables
      migrate_schema
    end

    # Runs a block holding the database lock
    #
    # @yield Block to run
    # @return [Object] The block's value
    def synchronize(&block)
      @monitor.synchronize(&block)
    end

    # Runs a block inside a database transaction, holding the lock
    #
    # @yield Block to run
    # @return [Object] The block's value
    def transaction(&block)
      synchronize { @db.transaction(&block) }
    end

    # @param sql [String] Statement to run
    # @param params [Array] Bind parameters
    # @return [Array<Hash>] Result rows
    def execute(sql, params = [])
      synchronize { @db.execute(sql, params) }
    end

    # @param sql [String] Statement to run
    # @param params [Array] Bind parameters
    # @return [Hash, nil] First result row
    def get_first_row(sql, params = [])
      synchronize { @db.get_first_row(sql, params) }
    end

    # @param sql [String] Statement to run
    # @param params [Array] Bind parameters
    # @return [Object, nil] First column of the first result row
    def get_first_value(sql, params = [])
      synchronize { @db.get_first_value(sql, params) }
    end

    # @return [Integer] Id of the row inserted by the last statement
    def last_insert_row_id
      synchronize { @db.last_insert_row_id }
    end

    # @return [Integer] Rows changed by the last statement
    def changes
      synchronize { @db.changes }
    end

    private

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

      @db.execute 'CREATE INDEX IF NOT EXISTS idx_queue_position ON queue_entries(position)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_queue_url ON queue_entries(url)'
    end

    # @return [Integer] Version of the schema currently on disk
    def current_schema_version
      table = @db.get_first_value(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
      )
      return 1 if table.nil? # No schema_version table = v1

      # An empty table is an invalid state but a recoverable one: treat as v1
      @db.get_first_value('SELECT version FROM schema_version') || 1
    end

    def migrate_schema
      fk_enabled = @db.get_first_value('PRAGMA foreign_keys')
      if fk_enabled != 1
        raise 'SQLite foreign key support is not enabled. This requires SQLite 3.6.19 or later. ' \
              'Please upgrade your SQLite installation.'
      end

      migrate_v1_to_v2 if current_schema_version == 1
    end

    def migrate_v1_to_v2
      @db.transaction do
        @db.execute <<-SQL
          CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY
          )
        SQL

        @db.execute <<-SQL
          CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK(length(name) <= 100)
          )
        SQL

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

        @db.execute <<-SQL
          CREATE INDEX IF NOT EXISTS idx_qeta_queue_entry
            ON queue_entry_tag_assignments(queue_entry_id)
        SQL

        @db.execute <<-SQL
          CREATE INDEX IF NOT EXISTS idx_qeta_tag
            ON queue_entry_tag_assignments(tag_id)
        SQL

        # The migration may be retried after a failure, so re-check the column
        columns = @db.execute('PRAGMA table_info(queue_entries)')
        unless columns.any? { |column| column['name'] == 'date' }
          @db.execute 'ALTER TABLE queue_entries ADD COLUMN date INTEGER'
        end

        @db.execute 'INSERT OR REPLACE INTO schema_version (version) VALUES (?)', [SCHEMA_VERSION]
      end
    rescue SQLite3::Exception => e
      warn "ERROR: Database migration v1->v2 failed: #{e.message}"
      warn 'Database may be in inconsistent state. Please restore from backup at ' \
           '~/.local/share/toy-browser/queue.db'
      raise # Re-raise to prevent browser startup with broken schema
    end
  end
end
