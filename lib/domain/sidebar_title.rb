require 'cgi'

module Domain
  # Pango markup for a sidebar list-item title.
  #
  # All three sidebar views (queue, history, tabs) draw a row's title the same
  # way: escaped, truncated to a maximum length, and wrapped in a bold span at a
  # size large enough to dominate the colourful tag pills beside it. This is the
  # single place that decides how that title is drawn, so the three views cannot
  # drift apart on size or escaping.
  module SidebarTitle
    # Pango named size for the title span; lives here so the size is defined once
    TITLE_SIZE = 'large'.freeze

    # Builds the Pango markup for a sidebar row's title.
    #
    # The text is HTML-escaped and truncated to +max_length+ characters
    # (exclusive, matching Ruby's `str[0, n]`), then wrapped in a bold span at
    # TITLE_SIZE. A nil or empty title yields valid markup for an empty title
    # rather than raising.
    #
    # @param title [String, nil] Title as supplied by the caller
    # @param max_length [Integer] Maximum number of characters to keep
    # @return [String] Pango markup string safe to assign to Gtk::Label#markup
    def self.markup(title, max_length: 61)
      truncated = title.to_s[0, max_length] || ''
      escaped = CGI.escapeHTML(truncated)
      "<span size='#{TITLE_SIZE}' weight='bold'>#{escaped}</span>"
    end
  end
end
