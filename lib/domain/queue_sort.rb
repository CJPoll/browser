# frozen_string_literal: true

module Domain
  # The order queue entries appear in the sidebar.
  #
  # `:position` is the queue's own order -- the repository already returns
  # entries ranked by position, so this mode hands the list back untouched.
  # The other two modes are display orderings the user picks from the sort
  # menu; neither changes the stored positions.
  module QueueSort
    # Every mode the sidebar offers, in menu order
    MODES = %i[position title date_published].freeze

    # Orders entries for display
    #
    # @param entries [Array<Domain::QueueEntry>] Entries in position order
    # @param mode [Symbol] One of {MODES}; anything else leaves the order alone
    # @return [Array<Domain::QueueEntry>] Entries in display order
    def self.apply(entries, mode)
      case mode
      when :title then by_title(entries)
      when :date_published then by_date_published(entries)
      else entries
      end
    end

    # Alphabetical by the text the row shows, ignoring case
    #
    # @param entries [Array<Domain::QueueEntry>]
    # @return [Array<Domain::QueueEntry>]
    def self.by_title(entries)
      entries.sort_by { |entry| entry.display_title.downcase }
    end

    # Newest publication date first, with entries of unknown date last
    #
    # @param entries [Array<Domain::QueueEntry>]
    # @return [Array<Domain::QueueEntry>]
    def self.by_date_published(entries)
      entries.sort do |a, b|
        date_a = a.published_at
        date_b = b.published_at

        if date_a.nil? && date_b.nil?
          0
        elsif date_a.nil?
          1
        elsif date_b.nil?
          -1
        else
          date_b <=> date_a
        end
      end
    end
  end
end
