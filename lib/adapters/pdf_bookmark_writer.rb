# frozen_string_literal: true

require 'hexapdf'
require 'tempfile'
require_relative 'process_launcher'
require_relative '../domain/pdf_outline'

module Adapters
  # Writes a bookmark outline into a PDF file.
  #
  # Everything here is the effect: opening the document, reading text off its
  # pages to find where each heading landed, and saving it again. Which
  # bookmarks the outline should contain is Domain::PdfOutline's answer.
  #
  # Two ways in, because the two callers differ in what they can afford to
  # wait for:
  #
  # - `add_bookmarks` does the work in this process (the user picked a PDF and
  #   is waiting for it).
  # - `add_bookmarks_later` hands it to a separate process (a print job has
  #   just finished, and a crash inside HexaPDF must not take the browser with
  #   it).
  class PdfBookmarkWriter
    PROJECT_ROOT = File.expand_path('../..', __dir__)

    # The script the background process runs. It receives the paths as
    # arguments -- nothing is interpolated into code, so a filename cannot
    # become Ruby or shell syntax.
    BACKGROUND_SCRIPT = File.join(PROJECT_ROOT, 'bin', 'add_pdf_bookmarks.rb')

    BACKGROUND_COMMAND = %w[bundle exec ruby].freeze

    # Hands the markdown to the background process through a file, since it is
    # a whole document rather than an argument.
    MARKDOWN_TEMP_FILE = lambda do |markdown|
      file = Tempfile.new(['markdown', '.md'])
      file.write(markdown)
      file.close
      file.path
    end

    # @param process_launcher [Adapters::ProcessLauncher] Starts the background process
    # @param temp_file_writer [#call] Receives markdown, returns the path it wrote it to
    def initialize(process_launcher: ProcessLauncher.new, temp_file_writer: MARKDOWN_TEMP_FILE)
      @process_launcher = process_launcher
      @temp_file_writer = temp_file_writer
    end

    # Adds bookmarks to a PDF, in this process
    #
    # @param pdf_path [String] Path to the PDF to modify in place
    # @param markdown [String, nil] The markdown the PDF was printed from
    # @return [Boolean] Whether the PDF was rewritten
    def add_bookmarks(pdf_path, markdown)
      unless File.exist?(pdf_path)
        warn "[PdfBookmarkWriter] No such PDF: #{pdf_path}"
        return false
      end

      headings = Domain::PdfOutline.headings(markdown)
      if headings.empty?
        warn '[PdfBookmarkWriter] No headings in the markdown; nothing to bookmark'
        return false
      end

      document = HexaPDF::Document.open(pdf_path)
      write_outline(document, locate_headings(document, headings))
      document.write(pdf_path, optimize: true)
      puts "[PdfBookmarkWriter] Added #{headings.size} bookmarks to #{pdf_path}"
      true
    rescue StandardError => e
      warn "[PdfBookmarkWriter] Failed to add bookmarks: #{e.class}: #{e.message}"
      warn e.backtrace.first(5).map { |line| "  #{line}" }.join("\n")
      false
    end

    # Adds bookmarks to a PDF in a separate, detached process
    #
    # The child waits for the print job to finish flushing the file before it
    # opens it, so this returns as soon as the process is started.
    #
    # @param pdf_path [String] Path to the PDF to modify in place
    # @param markdown [String] The markdown the PDF was printed from
    # @return [Integer] Process id of the background process
    def add_bookmarks_later(pdf_path, markdown)
      markdown_path = @temp_file_writer.call(markdown)

      @process_launcher.launch_detached(
        *BACKGROUND_COMMAND, BACKGROUND_SCRIPT, pdf_path, markdown_path,
        chdir: PROJECT_ROOT, out: $stdout, err: $stderr
      )
    end

    private

    # Finds the page each heading appears on, dropping those that are nowhere
    # to be found (a heading may be rendered as an image, or split across a
    # line break).
    #
    # @param document [HexaPDF::Document] The open PDF
    # @param headings [Array<Domain::PdfOutline::Heading>] Headings without pages
    # @return [Array<Domain::PdfOutline::Heading>] Headings with pages
    def locate_headings(document, headings)
      headings.filter_map do |heading|
        page = page_containing(document, heading.text)
        next unless page

        Domain::PdfOutline::Heading.new(text: heading.text, level: heading.level, page: page)
      end
    end

    # @param document [HexaPDF::Document] The open PDF
    # @param text [String] Text to look for
    # @return [Integer, nil] Zero-based page index, or nil if not found
    def page_containing(document, text)
      document.pages.each_with_index do |page, index|
        begin
          processor = TextExtractor.new
          page.process_contents(processor)
          return index if processor.text.include?(text)
        rescue StandardError => e
          # One unreadable page must not cost the whole outline
          warn "[PdfBookmarkWriter] Could not read page #{index + 1}: #{e.class}: #{e.message}"
          next
        end
      end
      nil
    end

    # @param document [HexaPDF::Document] The open PDF
    # @param headings [Array<Domain::PdfOutline::Heading>] Headings with pages
    # @return [void]
    def write_outline(document, headings)
      items = []

      Domain::PdfOutline.plan(headings).each do |bookmark|
        parent = bookmark.parent_index ? items[bookmark.parent_index] : document.outline
        items << parent.add_item(bookmark.text, destination: bookmark.page)
      end
    end

    # Collects the text drawn on a single PDF page
    class TextExtractor < HexaPDF::Content::Processor
      attr_reader :text

      def initialize
        super
        @text = +''
      end

      def show_text(string)
        @text << decode_text(string)
      end

      def show_text_with_positioning(array)
        array.each { |item| show_text(item) if item.is_a?(String) }
      end
    end
  end
end
