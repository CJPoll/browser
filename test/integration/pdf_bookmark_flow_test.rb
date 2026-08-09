require_relative '../test_helper'
require 'hexapdf'
require_relative '../../lib/managers/pdf_bookmark_manager'

# Integration test for the PDF bookmark flow: a real PDF, the real writer, no
# mocks. Proves the pieces line up -- Domain reads the headings, the adapter
# finds them in the PDF and writes an outline that a PDF viewer can show.
class PdfBookmarkFlowTest < Minitest::Test
  MARKDOWN = <<~MARKDOWN.freeze
    # Chapter One

    Some prose.

    ## Section A

    More prose.

    # Chapter Two
  MARKDOWN

  def setup
    @dir = Dir.mktmpdir('pdf-bookmark-flow')
    @pdf_path = File.join(@dir, 'notes.pdf')
    @manager = Managers::PdfBookmarkManager.new
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_a_printed_markdown_document_gets_a_bookmark_per_heading
    write_pdf(['Chapter One', 'Section A', 'Chapter Two'])

    assert_equal :added, @manager.add_bookmarks(@pdf_path, MARKDOWN)
    assert_equal ['Chapter One', 'Section A', 'Chapter Two'], outline_titles
  end

  def test_the_outline_nests_sections_under_their_chapter
    write_pdf(['Chapter One', 'Section A', 'Chapter Two'])
    @manager.add_bookmarks(@pdf_path, MARKDOWN)

    assert_equal [1, 2, 1], outline_levels
  end

  def test_each_bookmark_points_at_the_page_its_heading_is_on
    write_pdf(['Chapter One', 'Section A', 'Chapter Two'])
    @manager.add_bookmarks(@pdf_path, MARKDOWN)

    assert_equal [0, 1, 2], outline_page_indexes
  end

  def test_a_heading_that_is_nowhere_in_the_pdf_is_left_out
    write_pdf(['Chapter One', 'Chapter Two'])

    assert_equal :added, @manager.add_bookmarks(@pdf_path, MARKDOWN)
    assert_equal ['Chapter One', 'Chapter Two'], outline_titles
  end

  def test_a_pdf_printed_from_a_page_with_no_headings_is_left_alone
    write_pdf(['Just prose'])

    assert_equal :failed, @manager.add_bookmarks(@pdf_path, "no headings at all\n")
    assert_empty outline_titles
  end

  def test_the_pdf_still_has_all_of_its_pages_afterwards
    write_pdf(['Chapter One', 'Section A', 'Chapter Two'])
    @manager.add_bookmarks(@pdf_path, MARKDOWN)

    assert_equal 3, HexaPDF::Document.open(@pdf_path).pages.count
  end

  private

  # One page per string, with that string drawn on it
  def write_pdf(page_texts)
    document = HexaPDF::Document.new

    page_texts.each do |text|
      canvas = document.pages.add.canvas
      canvas.font('Helvetica', size: 24)
      canvas.text(text, at: [50, 700])
    end

    document.write(@pdf_path, optimize: true)
  end

  def outline_items
    document = HexaPDF::Document.open(@pdf_path)
    items = []
    document.outline.each_item { |item, level| items << [item, level] }
    items
  end

  def outline_titles
    outline_items.map { |item, _level| item[:Title] }
  end

  def outline_levels
    outline_items.map { |_item, level| level }
  end

  def outline_page_indexes
    document = HexaPDF::Document.open(@pdf_path)
    pages = document.pages.to_a
    items = []
    # The destination is a [page, :Fit] array; PDFArray resolves the reference
    document.outline.each_item { |item, _level| items << pages.index(item[:Dest][0]) }
    items
  end
end
