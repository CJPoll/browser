# frozen_string_literal: true

require 'sqlite3'
require_relative 'queue_database'
require_relative '../domain/queue_entry'

module Repositories
  # The `queue_entries` table: the ordered read/watch/do queue.
  #
  # Positions are 1-based and contiguous; this class is what keeps them that
  # way, renumbering on removal and shifting the intervening rows on a move.
  # Callers deal in `Domain::QueueEntry` and never see a position gap.
  class QueueRepository
    COLUMNS = 'id, url, title, favicon, position, added_at, date'

    # @param database [Repositories::QueueDatabase] Shared queue.db connection
    def initialize(database = QueueDatabase.new)
      @database = database
    end

    # Every entry, in queue order
    #
    # @return [Array<Domain::QueueEntry>]
    def all
      @database.execute("SELECT #{COLUMNS} FROM queue_entries ORDER BY position ASC")
               .map { |row| build_entry(row) }
    end

    # The entry at the front of the queue
    #
    # @return [Domain::QueueEntry, nil]
    def first
      row = @database.get_first_row(
        "SELECT #{COLUMNS} FROM queue_entries ORDER BY position ASC LIMIT 1"
      )
      row && build_entry(row)
    end

    # @param id [Integer, nil] Row id
    # @return [Domain::QueueEntry, nil]
    def find_by_id(id)
      return nil if id.nil?

      row = @database.get_first_row("SELECT #{COLUMNS} FROM queue_entries WHERE id = ?", [id])
      row && build_entry(row)
    end

    # @param url [String, nil] Exact URL
    # @return [Domain::QueueEntry, nil]
    def find_by_url(url)
      return nil if url.nil?

      row = @database.get_first_row("SELECT #{COLUMNS} FROM queue_entries WHERE url = ?", [url])
      row && build_entry(row)
    end

    # @param position [Integer, nil] 1-based rank
    # @return [Domain::QueueEntry, nil]
    def find_by_position(position)
      return nil if position.nil?

      row = @database.get_first_row(
        "SELECT #{COLUMNS} FROM queue_entries WHERE position = ?", [position]
      )
      row && build_entry(row)
    end

    # Entries with the given ids, in queue order
    #
    # @param ids [Array<Integer>] Row ids
    # @return [Array<Domain::QueueEntry>]
    def find_all_by_ids(ids)
      return [] if ids.nil? || ids.empty?

      placeholders = ids.map { '?' }.join(',')
      @database.execute(
        "SELECT #{COLUMNS} FROM queue_entries WHERE id IN (#{placeholders}) ORDER BY position ASC",
        ids
      ).map { |row| build_entry(row) }
    end

    # Appends an entry to the back of the queue
    #
    # @param entry [Domain::QueueEntry] Entry to store; its id and position are
    #   ignored, the database assigns them
    # @return [Domain::QueueEntry, nil] The stored entry with its id and
    #   position, or nil if the URL is already queued
    def add(entry)
      stored = nil

      # SQLite3::Database#transaction returns true, not the block's value, so
      # the stored entry is captured in a local rather than returned from it
      @database.transaction do
        max_position = @database.get_first_value('SELECT MAX(position) FROM queue_entries') || 0
        position = max_position + 1

        @database.execute(
          'INSERT INTO queue_entries (url, title, favicon, position, added_at) VALUES (?, ?, ?, ?, ?)',
          [entry.url, entry.title, entry.favicon_data, position, to_timestamp(entry.added_at)]
        )

        stored = entry.with(id: @database.last_insert_row_id, position: position)
      end

      stored
    rescue SQLite3::ConstraintException
      nil
    end

    # Removes an entry and closes the gap it leaves in the ordering
    #
    # @param id [Integer, nil] Row id
    # @return [Boolean] Whether anything was removed
    def remove(id)
      return false if id.nil?

      @database.synchronize do
        entry = find_by_id(id)
        return false unless entry

        @database.transaction do
          @database.execute('DELETE FROM queue_entries WHERE id = ?', [id])
          @database.execute(
            'UPDATE queue_entries SET position = position - 1 WHERE position > ?',
            [entry.position]
          )
        end

        true
      end
    end

    # Moves an entry to a new position, shifting the entries it passes
    #
    # @param id [Integer, nil] Row id
    # @param new_position [Integer] Desired 1-based rank, clamped to the queue
    # @return [Boolean] Whether the entry exists (true even when already there)
    def move(id, new_position)
      return false if id.nil?

      @database.synchronize do
        entry = find_by_id(id)
        return false unless entry

        old_position = entry.position
        return true if old_position == new_position

        max_position = @database.get_first_value('SELECT MAX(position) FROM queue_entries') || 0
        target = new_position.clamp(1, max_position)

        @database.transaction do
          if target < old_position
            @database.execute(
              'UPDATE queue_entries SET position = position + 1 WHERE position >= ? AND position < ?',
              [target, old_position]
            )
          else
            @database.execute(
              'UPDATE queue_entries SET position = position - 1 WHERE position > ? AND position <= ?',
              [old_position, target]
            )
          end

          @database.execute('UPDATE queue_entries SET position = ? WHERE id = ?', [target, id])
        end

        true
      end
    end

    # @param url [String] URL of the entry to update
    # @param title [String] New title
    # @return [void]
    def update_title(url, title)
      @database.execute('UPDATE queue_entries SET title = ? WHERE url = ?', [title, url])
      nil
    end

    # @param url [String] URL of the entry to update
    # @param favicon_data [String] PNG bytes
    # @return [void]
    def update_favicon(url, favicon_data)
      @database.execute('UPDATE queue_entries SET favicon = ? WHERE url = ?', [favicon_data, url])
      nil
    end

    # @param url [String] URL of the entry to update
    # @param published_at [Time] Publication date of the page
    # @return [void]
    def update_published_at(url, published_at)
      @database.execute(
        'UPDATE queue_entries SET date = ? WHERE url = ?', [to_timestamp(published_at), url]
      )
      nil
    end

    # @return [Integer] Number of queued entries
    def count
      @database.get_first_value('SELECT COUNT(*) FROM queue_entries') || 0
    end

    # The rank of the last entry. Equal to `count` while the ordering is
    # contiguous, which this class maintains; asked separately so a database
    # with gaps still moves entries to a position that exists.
    #
    # @return [Integer] Highest position in use, 0 when the queue is empty
    def max_position
      @database.get_first_value('SELECT MAX(position) FROM queue_entries') || 0
    end

    # Empties the queue
    #
    # @return [void]
    def clear_all
      @database.execute('DELETE FROM queue_entries')
      nil
    end

    private

    # @param row [Hash] Result row
    # @return [Domain::QueueEntry]
    def build_entry(row)
      Domain::QueueEntry.new(
        id: row['id'],
        url: row['url'],
        title: row['title'],
        favicon_data: row['favicon'],
        position: row['position'],
        added_at: from_timestamp(row['added_at']),
        published_at: from_timestamp(row['date'])
      )
    end

    # @param time [Time, nil] Time to store
    # @return [Integer, nil] Unix seconds
    def to_timestamp(time)
      time&.to_i
    end

    # @param seconds [Integer, nil] Unix seconds from the database
    # @return [Time, nil]
    def from_timestamp(seconds)
      seconds && Time.at(seconds)
    end
  end
end
