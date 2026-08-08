require 'minitest/autorun'
require 'fileutils'
require 'sqlite3'
require_relative '../../lib/repositories/queue_database'

# The queue database adopts files written by earlier versions of the browser,
# so these tests build a v1 database by hand and check the migration.
class QueueDatabaseTest < Minitest::Test
  def setup
    @db_path = "/tmp/test_queue_database_#{Process.pid}.db"
    FileUtils.rm_f(@db_path)
  end

  def teardown
    @database&.close
    FileUtils.rm_f(@db_path)
  end

  def open
    @database = Repositories::QueueDatabase.new(db_path: @db_path)
  end

  # Writes the schema the browser shipped before tags existed
  def write_v1_database
    db = SQLite3::Database.new(@db_path)
    db.execute <<-SQL
      CREATE TABLE queue_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT,
        favicon BLOB,
        position INTEGER NOT NULL,
        added_at INTEGER NOT NULL
      )
    SQL
    db.execute(
      'INSERT INTO queue_entries (url, title, position, added_at) VALUES (?, ?, ?, ?)',
      ['https://example.com/legacy', 'Legacy entry', 1, 1_600_000_000]
    )
    db.close
  end

  def table_names
    @database.execute("SELECT name FROM sqlite_master WHERE type='table'")
             .map { |row| row['name'] }
  end

  # === Fresh database ===

  def test_creates_the_directory_it_needs
    @db_path = "/tmp/test_queue_database_dir_#{Process.pid}/queue.db"
    FileUtils.rm_rf(File.dirname(@db_path))

    open

    assert File.exist?(@db_path)
  ensure
    @database&.close
    FileUtils.rm_rf(File.dirname(@db_path))
    @db_path = "/tmp/test_queue_database_#{Process.pid}.db"
  end

  def test_creates_every_table_on_a_fresh_database
    open

    %w[queue_entries tags queue_entry_tag_assignments schema_version].each do |table|
      assert_includes table_names, table
    end
  end

  def test_records_the_current_schema_version
    open

    assert_equal Repositories::QueueDatabase::SCHEMA_VERSION,
                 @database.get_first_value('SELECT version FROM schema_version')
  end

  def test_enables_foreign_key_enforcement
    open

    assert_equal 1, @database.get_first_value('PRAGMA foreign_keys')
  end

  # === Migration from v1 ===

  def test_migrates_a_v1_database_without_losing_entries
    write_v1_database

    open

    assert_equal 'Legacy entry',
                 @database.get_first_value('SELECT title FROM queue_entries')
  end

  def test_migration_adds_the_tag_tables
    write_v1_database

    open

    assert_includes table_names, 'tags'
    assert_includes table_names, 'queue_entry_tag_assignments'
  end

  def test_migration_adds_the_publication_date_column
    write_v1_database

    open
    columns = @database.execute('PRAGMA table_info(queue_entries)').map { |c| c['name'] }

    assert_includes columns, 'date'
  end

  def test_migration_adds_the_assignment_indexes
    write_v1_database

    open
    indexes = @database.execute("SELECT name FROM sqlite_master WHERE type='index'")
                       .map { |row| row['name'] }

    assert_includes indexes, 'idx_qeta_queue_entry'
    assert_includes indexes, 'idx_qeta_tag'
  end

  def test_migration_runs_only_once
    write_v1_database
    open
    @database.execute('INSERT INTO tags (name) VALUES (?)', ['Gaming'])
    @database.close

    open

    assert_equal 1, @database.get_first_value('SELECT COUNT(*) FROM tags')
  end

  # === Locking ===

  def test_synchronize_is_reentrant
    open

    result = @database.synchronize { @database.synchronize { :nested } }

    assert_equal :nested, result
  end
end
