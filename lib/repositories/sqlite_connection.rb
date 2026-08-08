# frozen_string_literal: true

require 'fileutils'
require 'sqlite3'

module Repositories
  # Connection boilerplate shared by the SQLite-backed repositories: create the
  # containing directory, open the database, and apply the settings every table
  # in this codebase depends on (hash rows, UTF-8).
  #
  # Deliberately *only* connection handling. Each repository still declares its
  # own schema and owns every SQL string that touches its table -- a shared
  # table-name-parameterised base class would unify four stores that merely
  # rhyme today.
  module SqliteConnection
    # Opens the database, creating its directory if needed
    #
    # @param db_path [String] Path to the SQLite file
    # @return [SQLite3::Database] The open connection
    def connect(db_path)
      FileUtils.mkdir_p(File.dirname(db_path))

      @db = SQLite3::Database.new(db_path)
      @db.results_as_hash = true
      @db.execute("PRAGMA encoding = 'UTF-8'")
      @db
    end

    # Closes the connection if it is open
    #
    # @return [void]
    def close
      @db.close if @db && !@db.closed?
    end
  end
end
