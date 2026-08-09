# frozen_string_literal: true

module Domain
  # What each file chooser in the browser offers to filter by.
  #
  # A descriptor, not a widget: `Filter` is a name plus the MIME types and
  # glob patterns that belong to it, and `FileChooser` turns one into a
  # `Gtk::FileFilter`. Which types a chooser offers -- and the decision to add
  # an image filter only when the page asked for images -- is a rule, so it is
  # testable without a dialog on screen.
  module FileFilters
    # @!attribute name [String] Label shown in the chooser's filter menu
    # @!attribute mime_types [Array<String>] MIME types this filter accepts
    # @!attribute patterns [Array<String>] Glob patterns this filter accepts
    Filter = Struct.new(:name, :mime_types, :patterns, keyword_init: true)

    ALL_FILES = Filter.new(name: 'All Files', mime_types: [], patterns: ['*']).freeze

    PDF_FILES = Filter.new(
      name: 'PDF Files',
      mime_types: ['application/pdf'],
      patterns: ['*.pdf']
    ).freeze

    HTML_FILES = Filter.new(
      name: 'HTML Files',
      mime_types: ['text/html'],
      patterns: ['*.html', '*.htm']
    ).freeze

    MARKDOWN_FILES = Filter.new(
      name: 'Markdown Files',
      mime_types: ['text/markdown'],
      patterns: ['*.md', '*.markdown']
    ).freeze

    IMAGES = Filter.new(name: 'Images', mime_types: ['image/*'], patterns: []).freeze

    # Extensions spelled out for the upload chooser. WebKit's own filter
    # matches on MIME type, which the desktop does not always agree with --
    # GIFs in particular -- so the patterns are listed in both cases.
    IMAGE_EXTENSIONS = %w[gif png jpg jpeg webp bmp tiff svg ico].freeze

    ALL_IMAGES = Filter.new(
      name: 'All Images',
      mime_types: ['image/*'],
      patterns: IMAGE_EXTENSIONS.flat_map { |ext| ["*.#{ext}", "*.#{ext.upcase}"] }
    ).freeze

    # Filters for Ctrl+O. "All Files" comes first because the chooser selects
    # the first filter by default, and the browser opens more than these four
    # types.
    #
    # @return [Array<Filter>]
    def self.open_file
      [ALL_FILES, HTML_FILES, MARKDOWN_FILES, PDF_FILES, IMAGES]
    end

    # Filters for choosing a PDF to add bookmarks to
    #
    # @return [Array<Filter>]
    def self.pdf
      [PDF_FILES]
    end

    # Filters to add to an `<input type="file">` chooser, alongside the filter
    # WebKit supplies from the element's `accept` attribute
    #
    # @param mime_types [Array<String>, nil] Types the page said it accepts
    # @return [Array<Filter>]
    def self.for_upload(mime_types)
      accepts_images = (mime_types || []).any? { |type| type.start_with?('image/') }

      accepts_images ? [ALL_IMAGES, ALL_FILES] : [ALL_FILES]
    end
  end
end
