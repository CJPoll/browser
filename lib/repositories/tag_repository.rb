# frozen_string_literal: true

require 'sqlite3'
require_relative 'queue_database'
require_relative '../domain/tag'
require_relative '../domain/tag_usage'

module Repositories
  # The `tags` and `queue_entry_tag_assignments` tables.
  #
  # Names are matched with SQLite's `COLLATE NOCASE`, so "YouTube" and
  # "youtube" are the same tag; the stored spelling is whichever was written
  # first. Normalization and length validation happen before a name arrives
  # here (`Domain::TagName`, applied by `Managers::QueueManager`) -- the
  # table's `CHECK(length(name) <= 100)` is the backstop, not the rule.
  #
  # This repository deals in tags and assignments only. "Which entries carry
  # these tags" is answered as a list of entry ids; the manager hands those to
  # `QueueRepository`, so neither repository writes SQL against the other's
  # table.
  class TagRepository
    # @param database [Repositories::QueueDatabase] Shared queue.db connection
    def initialize(database = QueueDatabase.new)
      @database = database
    end

    # Finds a tag by name, creating it if it does not exist
    #
    # @param name [String] Normalized tag name
    # @return [Domain::Tag, nil] The tag, or nil if the name is unstorable
    def create_or_find(name)
      return nil if name.nil?

      @database.synchronize do
        existing = find_by_name(name)
        return existing if existing

        @database.execute('INSERT INTO tags (name) VALUES (?)', [name])
        Domain::Tag.new(id: @database.last_insert_row_id, name: name)
      end
    rescue SQLite3::ConstraintException
      # Length check violated; the caller validates first, so this is a backstop
      nil
    end

    # @param name [String, nil] Tag name, matched case-insensitively
    # @return [Domain::Tag, nil]
    def find_by_name(name)
      return nil if name.nil?

      row = @database.get_first_row(
        'SELECT id, name FROM tags WHERE name = ? COLLATE NOCASE', [name]
      )
      row && build_tag(row)
    end

    # @param id [Integer, nil] Row id
    # @return [Domain::Tag, nil]
    def find_by_id(id)
      return nil if id.nil?

      row = @database.get_first_row('SELECT id, name FROM tags WHERE id = ?', [id])
      row && build_tag(row)
    end

    # Every tag, alphabetically
    #
    # @return [Array<Domain::Tag>]
    def all
      @database.execute('SELECT id, name FROM tags ORDER BY name COLLATE NOCASE ASC')
               .map { |row| build_tag(row) }
    end

    # @param tag_id [Integer, nil] Row id
    # @return [Boolean] Whether anything was deleted
    def delete(tag_id)
      return false if tag_id.nil?

      @database.synchronize do
        @database.execute('DELETE FROM tags WHERE id = ?', [tag_id])
        @database.changes > 0
      end
    end

    # Assigns a tag to a queue entry
    #
    # @param entry_id [Integer] Queue entry id
    # @param tag_id [Integer] Tag id
    # @return [Boolean] Whether a new assignment was created
    def assign(entry_id, tag_id)
      @database.synchronize do
        return false if assigned?(entry_id, tag_id)

        @database.execute(
          'INSERT INTO queue_entry_tag_assignments (queue_entry_id, tag_id) VALUES (?, ?)',
          [entry_id, tag_id]
        )
        true
      end
    end

    # @param entry_id [Integer] Queue entry id
    # @param tag_id [Integer] Tag id
    # @return [Boolean] Whether an assignment existed
    def assigned?(entry_id, tag_id)
      !@database.get_first_value(
        'SELECT id FROM queue_entry_tag_assignments WHERE queue_entry_id = ? AND tag_id = ?',
        [entry_id, tag_id]
      ).nil?
    end

    # @param entry_id [Integer] Queue entry id
    # @param tag_id [Integer] Tag id
    # @return [Boolean] Whether an assignment was removed
    def unassign(entry_id, tag_id)
      @database.synchronize do
        @database.execute(
          'DELETE FROM queue_entry_tag_assignments WHERE queue_entry_id = ? AND tag_id = ?',
          [entry_id, tag_id]
        )
        @database.changes > 0
      end
    end

    # Tags assigned to an entry, alphabetically
    #
    # @param entry_id [Integer, nil] Queue entry id
    # @return [Array<Domain::Tag>]
    def tags_for_entry(entry_id)
      return [] if entry_id.nil?

      @database.execute(<<-SQL, [entry_id]).map { |row| build_tag(row) }
        SELECT t.id, t.name
        FROM tags t
        INNER JOIN queue_entry_tag_assignments qeta ON t.id = qeta.tag_id
        WHERE qeta.queue_entry_id = ?
        ORDER BY t.name COLLATE NOCASE ASC
      SQL
    end

    # Ids of the entries carrying *every* one of the given tags
    #
    # @param tag_ids [Array<Integer>] Tag ids
    # @return [Array<Integer>] Queue entry ids
    def entry_ids_with_all_tags(tag_ids)
      return [] if tag_ids.nil? || tag_ids.empty?

      placeholders = tag_ids.map { '?' }.join(',')

      @database.execute(<<-SQL, tag_ids).map { |row| row['queue_entry_id'] }
        SELECT qeta.queue_entry_id
        FROM queue_entry_tag_assignments qeta
        WHERE qeta.tag_id IN (#{placeholders})
        GROUP BY qeta.queue_entry_id
        HAVING COUNT(DISTINCT qeta.tag_id) = #{tag_ids.length}
      SQL
    end

    # How many entries carry each tag, including tags carried by none
    #
    # @return [Array<Domain::TagUsage>] Alphabetical by tag name
    def usage_counts
      @database.execute(<<-SQL).map { |row| build_usage(row) }
        SELECT
          t.id AS tag_id,
          t.name AS tag_name,
          COUNT(qeta.queue_entry_id) AS count
        FROM tags t
        LEFT JOIN queue_entry_tag_assignments qeta ON t.id = qeta.tag_id
        GROUP BY t.id, t.name
        ORDER BY t.name COLLATE NOCASE ASC
      SQL
    end

    private

    # @param row [Hash] Result row
    # @return [Domain::Tag]
    def build_tag(row)
      Domain::Tag.new(id: row['id'], name: row['name'])
    end

    # @param row [Hash] Result row
    # @return [Domain::TagUsage]
    def build_usage(row)
      Domain::TagUsage.new(
        tag: Domain::Tag.new(id: row['tag_id'], name: row['tag_name']),
        count: row['count']
      )
    end
  end
end
