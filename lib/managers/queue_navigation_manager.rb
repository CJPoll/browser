# frozen_string_literal: true

require_relative '../domain/queue_traversal'
require_relative 'queue_manager'

module Managers
  # Moving through the queue from the page the browser is showing.
  #
  # Split from `QueueManager` because traversal is a separate concern from
  # storage: what "next" means when the current page is not in the queue, which
  # way the queue wraps, and what to show after removing the page you just
  # finished. The rules themselves are pure and live in
  # `Domain::QueueTraversal`; this class supplies the queue they operate on and
  # applies their answer.
  #
  # It drives `QueueManager` rather than the repositories directly -- that is
  # the queue subdomain's public API, so navigation gets validation and tag
  # cascades for free.
  class QueueNavigationManager
    # @param queue_manager [Managers::QueueManager] The queue to traverse
    def initialize(queue_manager)
      @queue_manager = queue_manager
    end

    # The entry after the current page, wrapping at the end
    #
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] nil when the queue is empty
    def next_entry(current_url)
      Domain::QueueTraversal.next_after(@queue_manager.all, current_url)
    end

    # The entry before the current page, wrapping at the start
    #
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] nil when the queue is empty
    def previous_entry(current_url)
      Domain::QueueTraversal.previous_before(@queue_manager.all, current_url)
    end

    # Removes the current page from the queue and reports where to go next
    #
    # The URL is matched loosely, so a video that has gained a `&t=90s`
    # timestamp is still recognised as the entry that was queued.
    #
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] Entry that took the freed position, or
    #   nil if the page was not queued or was the last entry
    def remove_current_and_advance(current_url)
      @queue_manager.remove_by_url(current_url)
    end

    # Moves the current page one place towards the front
    #
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] The entry that moved, or nil if the
    #   page is not queued or is already at the front
    def move_current_up(current_url)
      move_current(current_url) { |entry| @queue_manager.move_up(entry.id) }
    end

    # Moves the current page one place towards the back
    #
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] The entry that moved, or nil if the
    #   page is not queued or is already at the back
    def move_current_down(current_url)
      move_current(current_url) { |entry| @queue_manager.move_down(entry.id) }
    end

    private

    # Looks up the current page and applies a move to it. The lookup is exact,
    # matching the keyboard shortcuts' existing behaviour.
    #
    # @param current_url [String, nil] URL the browser is showing
    # @yield [Domain::QueueEntry] Performs the move, returning whether it happened
    # @return [Domain::QueueEntry, nil] The entry that moved
    def move_current(current_url)
      entry = @queue_manager.find_by_url(current_url)
      return nil unless entry

      yield(entry) ? entry : nil
    end
  end
end
