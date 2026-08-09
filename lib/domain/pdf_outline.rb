# frozen_string_literal: true

module Domain
  # Turns a markdown document into the bookmark tree a PDF viewer shows in its
  # sidebar.
  #
  # Two pure steps, either side of the one impure thing in the middle (finding
  # which page each heading landed on, which only the PDF itself can answer):
  #
  #   headings(markdown)  ->  [Heading]        # text and level, no page yet
  #   ...adapter fills in each page...
  #   plan(headings)      ->  [Bookmark]       # flat list, each naming its parent
  #
  # The plan is deliberately flat: a bookmark names its parent by index, so the
  # adapter can create the items in order and look each parent up in what it
  # has already created.
  module PdfOutline
    # A markdown heading. `page` is the zero-based page index it appears on,
    # and is nil until the PDF has been searched for it.
    Heading = Struct.new(:text, :level, :page, keyword_init: true)

    # One entry in the PDF outline. `parent_index` indexes into the plan
    # itself; nil means the bookmark sits at the top level.
    Bookmark = Struct.new(:text, :page, :parent_index, keyword_init: true)

    # Raised when the heading levels cannot be arranged into a tree. See the
    # comment on `plan` -- this is a preserved wart, not a design.
    class MalformedHeadingLevels < StandardError; end

    # ATX headings only, one to six hashes followed by whitespace and text.
    HEADING_PATTERN = /^([#]{1,6})\s+(.+?)$/.freeze

    # Reads the headings out of a markdown document
    #
    # @param markdown [String, nil] Markdown source
    # @return [Array<Heading>] Headings in document order, without page numbers
    def self.headings(markdown)
      return [] unless markdown

      markdown.each_line.filter_map do |line|
        match = HEADING_PATTERN.match(line)
        next unless match

        Heading.new(text: match[2].strip, level: match[1].length, page: nil)
      end
    end

    # Arranges located headings into a bookmark tree
    #
    # A heading nests under the most recent heading of a shallower level. The
    # stack that tracks those parents is indexed by level, so a document that
    # skips a level leaves a gap in it -- and a later heading that lands
    # exactly on the gap has no parent to attach to. That case raises rather
    # than silently re-parenting, because the original implementation crashed
    # there and the caller's report ("failed to add bookmarks") is what users
    # have seen since.
    #
    # @param headings [Array<Heading>] Headings with their page numbers filled in
    # @return [Array<Bookmark>] Flat plan, each bookmark naming its parent by index
    # @raise [MalformedHeadingLevels] When a heading lands on a skipped level
    def self.plan(headings)
      parent_indexes = []

      headings.each_with_index.map do |heading, index|
        parent_indexes.pop while parent_indexes.size >= heading.level

        bookmark = Bookmark.new(
          text: heading.text,
          page: heading.page,
          parent_index: parent_index_from(parent_indexes, heading)
        )

        parent_indexes[heading.level - 1] = index
        bookmark
      end
    end

    # @param parent_indexes [Array<Integer, nil>] Stack of parents by level
    # @param heading [Heading] The heading being placed
    # @return [Integer, nil] Index of the parent bookmark, or nil for top level
    def self.parent_index_from(parent_indexes, heading)
      return nil if parent_indexes.empty?

      parent = parent_indexes.last
      if parent.nil?
        raise MalformedHeadingLevels,
              "heading #{heading.text.inspect} is at level #{heading.level}, " \
              'which the document skipped over'
      end

      parent
    end
    private_class_method :parent_index_from
  end
end
