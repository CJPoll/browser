# frozen_string_literal: true

require_relative '../domain/queue_entry'
require_relative '../domain/tag_name'
require_relative '../domain/url_matcher'
require_relative '../repositories/queue_database'
require_relative '../repositories/queue_repository'
require_relative '../repositories/tag_repository'

module Managers
  # The read/watch/do queue: adding, removing, reordering, metadata and tags.
  #
  # This is the queue subdomain's public API. It owns the rules that are not
  # the database's -- which URLs the queue accepts, what a tag name normalizes
  # to, whether an entry and tag both exist before they are linked -- and hands
  # storage to `QueueRepository` and `TagRepository`, which share one
  # connection so the two tables stay in one transaction scope.
  #
  # Traversal (next/previous/remove-and-navigate) lives in
  # `Managers::QueueNavigationManager`, which drives this class.
  class QueueManager
    # @param database [Repositories::QueueDatabase, nil] Shared connection;
    #   defaults to the real queue.db when no repositories are supplied
    # @param queue_repository [Repositories::QueueRepository, nil] Override for tests
    # @param tag_repository [Repositories::TagRepository, nil] Override for tests
    # @param clock [#call] Returns the current time
    def initialize(database: nil, queue_repository: nil, tag_repository: nil,
                   clock: -> { Time.now })
      if queue_repository && tag_repository
        @queue_repository = queue_repository
        @tag_repository = tag_repository
      else
        @database = database || Repositories::QueueDatabase.new
        @queue_repository = queue_repository || Repositories::QueueRepository.new(@database)
        @tag_repository = tag_repository || Repositories::TagRepository.new(@database)
      end

      @clock = clock
    end

    # Closes the underlying database, when this manager opened one
    #
    # @return [void]
    def close
      @database&.close
    end

    # ========================================
    # Entries
    # ========================================

    # Appends a URL to the queue
    #
    # @param url [String, nil] URL to queue
    # @param title [String, nil] Page title, when already known
    # @param favicon_data [String, nil] PNG bytes, when already known
    # @return [Symbol] :added, :already_exists or :invalid_url
    def add(url, title = nil, favicon_data = nil)
      return :invalid_url unless Domain::QueueEntry.queueable_url?(url)

      entry = Domain::QueueEntry.new(
        url: url,
        title: title,
        favicon_data: favicon_data,
        added_at: @clock.call
      )

      @queue_repository.add(entry) ? :added : :already_exists
    end

    # @return [Array<Domain::QueueEntry>] Every entry, in queue order
    def all
      @queue_repository.all
    end

    # @return [Domain::QueueEntry, nil] Front of the queue
    def first
      @queue_repository.first
    end

    # @return [Integer] Number of queued entries
    def count
      @queue_repository.count
    end

    # @param id [Integer, nil] Row id
    # @return [Domain::QueueEntry, nil]
    def find_by_id(id)
      @queue_repository.find_by_id(id)
    end

    # @param url [String, nil] Exact URL
    # @return [Domain::QueueEntry, nil]
    def find_by_url(url)
      @queue_repository.find_by_url(url)
    end

    # Finds an entry whose URL refers to the same page, tolerating the tracking
    # and timestamp parameters sites add while you are looking at them
    #
    # @param url [String, nil] URL as the browser currently reports it
    # @return [Domain::QueueEntry, nil]
    def find_by_url_fuzzy(url)
      @queue_repository.all.find { |entry| Domain::UrlMatcher.match?(entry.url, url) }
    end

    # Removes an entry and reports what took its place
    #
    # @param id [Integer, nil] Row id
    # @return [Domain::QueueEntry, nil] Entry that moved into the freed
    #   position, or nil if the entry was last or did not exist
    def remove_by_id(id)
      entry = @queue_repository.find_by_id(id)
      return nil unless entry

      position = entry.position
      return nil unless @queue_repository.remove(id)

      @queue_repository.find_by_position(position)
    end

    # Removes the entry for a URL, matched loosely, and reports what took its place
    #
    # @param url [String, nil] URL as the browser currently reports it
    # @return [Domain::QueueEntry, nil]
    def remove_by_url(url)
      entry = find_by_url_fuzzy(url)
      return nil unless entry

      remove_by_id(entry.id)
    end

    # @param id [Integer, nil] Row id
    # @param new_position [Integer] Desired 1-based rank
    # @return [Boolean] Whether the entry exists
    def move(id, new_position)
      @queue_repository.move(id, new_position)
    end

    # @param id [Integer, nil] Row id
    # @return [Boolean] Whether the entry moved
    def move_up(id)
      entry = @queue_repository.find_by_id(id)
      return false unless entry
      return false if entry.position <= 1

      @queue_repository.move(id, entry.position - 1)
    end

    # @param id [Integer, nil] Row id
    # @return [Boolean] Whether the entry moved
    def move_down(id)
      entry = @queue_repository.find_by_id(id)
      return false unless entry
      return false if entry.position >= @queue_repository.max_position

      @queue_repository.move(id, entry.position + 1)
    end

    # @param url [String, nil] URL of the entry to update
    # @param title [String, nil] Fetched title
    # @return [void]
    def update_title(url, title)
      return if url.nil? || title.nil?

      @queue_repository.update_title(url, title)
    end

    # @param url [String, nil] URL of the entry to update
    # @param favicon_data [String, nil] PNG bytes
    # @return [void]
    def update_favicon(url, favicon_data)
      return if url.nil? || favicon_data.nil?

      @queue_repository.update_favicon(url, favicon_data)
    end

    # @param url [String, nil] URL of the entry to update
    # @param published_at [Time, nil] Publication date of the page
    # @return [void]
    def update_published_at(url, published_at)
      return if url.nil? || published_at.nil?

      @queue_repository.update_published_at(url, published_at)
    end

    # Empties the queue
    #
    # @return [void]
    def clear_all
      @queue_repository.clear_all
    end

    # ========================================
    # Tags
    # ========================================

    # Finds a tag by name, creating it if it does not exist
    #
    # @param tag_name [String, nil] Tag name as typed
    # @return [Domain::Tag, nil] The tag, or nil if the name is unusable
    def create_or_find_tag(tag_name)
      return nil unless Domain::TagName.valid?(tag_name)

      @tag_repository.create_or_find(Domain::TagName.normalize(tag_name))
    end

    # @param tag_name [String, nil] Tag name as typed
    # @return [Domain::Tag, nil]
    def find_tag_by_name(tag_name)
      normalized = Domain::TagName.normalize(tag_name)
      return nil unless normalized

      @tag_repository.find_by_name(normalized)
    end

    # @param tag_id [Integer, nil] Tag id
    # @return [Domain::Tag, nil]
    def find_tag_by_id(tag_id)
      @tag_repository.find_by_id(tag_id)
    end

    # @return [Array<Domain::Tag>] Every tag, alphabetically
    def all_tags
      @tag_repository.all
    end

    # Assigns an existing tag to an existing entry
    #
    # @param entry_id [Integer, nil] Queue entry id
    # @param tag_id [Integer, nil] Tag id
    # @return [Symbol] :assigned, :already_assigned, :invalid_entry,
    #   :invalid_tag or :invalid_params
    def assign_tag(entry_id, tag_id)
      return :invalid_params if entry_id.nil? || tag_id.nil?
      return :invalid_entry unless @queue_repository.find_by_id(entry_id)
      return :invalid_tag unless @tag_repository.find_by_id(tag_id)

      @tag_repository.assign(entry_id, tag_id) ? :assigned : :already_assigned
    end

    # @param entry_id [Integer, nil] Queue entry id
    # @param tag_id [Integer, nil] Tag id
    # @return [Symbol] :unassigned, :not_assigned or :invalid_params
    def unassign_tag(entry_id, tag_id)
      return :invalid_params if entry_id.nil? || tag_id.nil?

      @tag_repository.unassign(entry_id, tag_id) ? :unassigned : :not_assigned
    end

    # Assigns a tag by name, creating the tag if needed
    #
    # @param entry_id [Integer, nil] Queue entry id
    # @param tag_name [String, nil] Tag name as typed
    # @return [Symbol] As `assign_tag`
    def assign_tag_by_name(entry_id, tag_name)
      return :invalid_params if entry_id.nil?

      tag = create_or_find_tag(tag_name)
      return :invalid_params if tag.nil?

      assign_tag(entry_id, tag.id)
    end

    # @param entry_id [Integer, nil] Queue entry id
    # @param tag_name [String, nil] Tag name as typed
    # @return [Symbol] As `unassign_tag`
    def unassign_tag_by_name(entry_id, tag_name)
      return :invalid_params if entry_id.nil?

      normalized = Domain::TagName.normalize(tag_name)
      return :invalid_params if normalized.nil?

      tag = @tag_repository.find_by_name(normalized)
      return :not_assigned unless tag

      unassign_tag(entry_id, tag.id)
    end

    # @param entry_id [Integer, nil] Queue entry id
    # @return [Array<Domain::Tag>] Tags on the entry, alphabetically
    def tags_for_entry(entry_id)
      @tag_repository.tags_for_entry(entry_id)
    end

    # @param tag_id [Integer, nil] Tag id
    # @return [Array<Domain::QueueEntry>] Entries carrying the tag, in queue order
    def entries_with_tag(tag_id)
      return [] if tag_id.nil?

      entries_with_tags([tag_id])
    end

    # Entries carrying *every* one of the given tags
    #
    # @param tag_ids [Array<Integer>, nil] Tag ids
    # @return [Array<Domain::QueueEntry>] In queue order
    def entries_with_tags(tag_ids)
      entry_ids = @tag_repository.entry_ids_with_all_tags(tag_ids)
      return [] if entry_ids.empty?

      @queue_repository.find_all_by_ids(entry_ids)
    end

    # Entries matching a tag filter, where filtering by nothing means everything
    #
    # The sidebar's filter starts empty and the user narrows from there, so an
    # empty tag list is not "no entries match" -- it is "no filter applied".
    # That rule lives here rather than in the widget, which only tracks which
    # tags the user has ticked.
    #
    # @param tag_ids [Array<Integer>, nil] Tag ids the user is filtering by
    # @return [Array<Domain::QueueEntry>] In queue order
    def entries_for_filter(tag_ids)
      return all if tag_ids.nil? || tag_ids.empty?

      entries_with_tags(tag_ids)
    end

    # @return [Array<Domain::TagUsage>] Every tag with its carrier count
    def tag_usage_counts
      @tag_repository.usage_counts
    end

    # Tags currently carried by at least one queue entry, for the filter popover.
    # Reuses the usage counts rather than a second query.
    # @return [Array<Domain::TagUsage>] In-use tags, alphabetical by name
    def tags_in_use
      tag_usage_counts.select(&:in_use?)
    end

    # @param tag_id [Integer, nil] Tag id
    # @return [Symbol] :deleted, :not_found or :invalid_params
    def delete_tag(tag_id)
      return :invalid_params if tag_id.nil?

      @tag_repository.delete(tag_id) ? :deleted : :not_found
    end
  end
end
