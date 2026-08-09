# frozen_string_literal: true

require_relative '../adapters/pdf_bookmark_writer'
require_relative '../domain/print_output'

module Managers
  # Decides when a PDF gets a bookmark outline written into it.
  #
  # Two callers, two answers:
  #
  # - A finished print job reports where it wrote (`add_bookmarks_for_print`).
  #   Only a PDF printed from a markdown document is worth following up on,
  #   and the work goes to a separate process so a failure inside a PDF
  #   library cannot take the browser down with it.
  # - The user picked a PDF themselves (`add_bookmarks`). There is nothing to
  #   decide, so it runs here and reports what happened.
  class PdfBookmarkManager
    # @param writer [Adapters::PdfBookmarkWriter] Performs the write
    def initialize(writer: Adapters::PdfBookmarkWriter.new)
      @writer = writer
    end

    # Adds bookmarks to a PDF the user chose
    #
    # Blocking: the caller runs it off the main loop.
    #
    # @param pdf_path [String, nil] Path to the PDF
    # @param markdown [String, nil] Markdown the PDF was printed from
    # @return [Symbol] :added, :failed, :no_pdf or :no_markdown
    def add_bookmarks(pdf_path, markdown)
      return :no_pdf if blank?(pdf_path)
      return :no_markdown if blank?(markdown)

      @writer.add_bookmarks(pdf_path, markdown) ? :added : :failed
    end

    # Adds bookmarks to whatever a print job just produced, if it produced a
    # PDF from a markdown document
    #
    # @param output_uri [String, nil] The job's `output-uri` print setting
    # @param markdown [String, nil] Markdown the page was rendered from, if any
    # @return [Symbol] :scheduled, :not_a_pdf or :no_markdown
    def add_bookmarks_for_print(output_uri, markdown)
      pdf_path = Domain::PrintOutput.pdf_path(output_uri)
      return :not_a_pdf unless pdf_path
      return :no_markdown if blank?(markdown)

      @writer.add_bookmarks_later(pdf_path, markdown)
      :scheduled
    end

    private

    # @param value [String, nil]
    # @return [Boolean]
    def blank?(value)
      value.nil? || value.empty?
    end
  end
end
