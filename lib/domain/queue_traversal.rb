# frozen_string_literal: true

module Domain
  # Moving through the queue from wherever the browser currently is.
  #
  # The queue wraps: stepping forward from the last entry lands on the first,
  # and stepping back from the first lands on the last. When the current URL is
  # not in the queue at all there is no "next" relative to it, so traversal
  # starts at the near end -- the first entry going forward, the last going
  # back.
  #
  # The current URL is matched **exactly**, not with `Domain::UrlMatcher`. A
  # page that has since gained a `&t=90s` timestamp therefore counts as "not in
  # the queue" and restarts traversal at the end. This is the behaviour the
  # keyboard shortcuts have always had; it is preserved deliberately and pinned
  # by a test.
  module QueueTraversal
    # The entry after the one at `current_url`
    #
    # @param entries [Array<Domain::QueueEntry>] Queue in position order
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] Next entry, or nil if the queue is empty
    def self.next_after(entries, current_url)
      return nil if entries.nil? || entries.empty?

      index = index_of(entries, current_url)
      return entries.first unless index

      entries[(index + 1) % entries.length]
    end

    # The entry before the one at `current_url`
    #
    # @param entries [Array<Domain::QueueEntry>] Queue in position order
    # @param current_url [String, nil] URL the browser is showing
    # @return [Domain::QueueEntry, nil] Previous entry, or nil if the queue is empty
    def self.previous_before(entries, current_url)
      return nil if entries.nil? || entries.empty?

      index = index_of(entries, current_url)
      return entries.last unless index

      entries[(index - 1) % entries.length]
    end

    # @param entries [Array<Domain::QueueEntry>] Queue in position order
    # @param current_url [String, nil] URL the browser is showing
    # @return [Integer, nil] Index of the entry at that exact URL
    def self.index_of(entries, current_url)
      return nil if current_url.nil?

      entries.find_index { |entry| entry.url == current_url }
    end
  end
end
