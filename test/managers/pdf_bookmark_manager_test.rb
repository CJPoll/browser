require_relative '../test_helper'
require_relative '../../lib/managers/pdf_bookmark_manager'

# Tests for Managers::PdfBookmarkManager - when a PDF earns an outline
class PdfBookmarkManagerTest < Minitest::Test
  # Records what it was asked to write instead of touching a PDF
  class MockWriter
    attr_reader :immediate, :deferred

    def initialize(result: true)
      @result = result
      @immediate = []
      @deferred = []
    end

    def add_bookmarks(pdf_path, markdown)
      @immediate << [pdf_path, markdown]
      @result
    end

    def add_bookmarks_later(pdf_path, markdown)
      @deferred << [pdf_path, markdown]
      1234
    end
  end

  MARKDOWN = "# Chapter\n"
  PDF_URI = 'file:///home/me/notes.pdf'

  def setup
    @writer = MockWriter.new
    @manager = Managers::PdfBookmarkManager.new(writer: @writer)
  end

  # ============================================================
  # add_bookmarks
  # ============================================================

  def test_writes_bookmarks_to_the_chosen_pdf
    assert_equal :added, @manager.add_bookmarks('/home/me/notes.pdf', MARKDOWN)
    assert_equal [['/home/me/notes.pdf', MARKDOWN]], @writer.immediate
  end

  def test_reports_a_failed_write
    manager = Managers::PdfBookmarkManager.new(writer: MockWriter.new(result: false))

    assert_equal :failed, manager.add_bookmarks('/home/me/notes.pdf', MARKDOWN)
  end

  def test_does_not_write_without_a_pdf
    assert_equal :no_pdf, @manager.add_bookmarks(nil, MARKDOWN)
    assert_empty @writer.immediate
  end

  def test_does_not_write_without_markdown
    assert_equal :no_markdown, @manager.add_bookmarks('/home/me/notes.pdf', nil)
    assert_empty @writer.immediate
  end

  def test_treats_empty_markdown_as_none
    assert_equal :no_markdown, @manager.add_bookmarks('/home/me/notes.pdf', '')
  end

  # ============================================================
  # add_bookmarks_for_print
  # ============================================================

  def test_schedules_a_background_write_for_a_printed_pdf
    assert_equal :scheduled, @manager.add_bookmarks_for_print(PDF_URI, MARKDOWN)
    assert_equal [['/home/me/notes.pdf', MARKDOWN]], @writer.deferred
  end

  def test_a_printed_pdf_is_never_written_in_this_process
    @manager.add_bookmarks_for_print(PDF_URI, MARKDOWN)

    assert_empty @writer.immediate, 'a PDF library crash must not reach the browser'
  end

  def test_ignores_a_job_that_went_to_a_printer_rather_than_a_file
    assert_equal :not_a_pdf, @manager.add_bookmarks_for_print(nil, MARKDOWN)
    assert_empty @writer.deferred
  end

  def test_ignores_a_job_that_produced_something_other_than_a_pdf
    assert_equal :not_a_pdf, @manager.add_bookmarks_for_print('file:///home/me/notes.ps', MARKDOWN)
    assert_empty @writer.deferred
  end

  # A page that is not a rendered markdown document has no headings to build an
  # outline from, so printing it produces a plain PDF.
  def test_ignores_a_pdf_printed_from_a_page_that_is_not_markdown
    assert_equal :no_markdown, @manager.add_bookmarks_for_print(PDF_URI, nil)
    assert_empty @writer.deferred
  end

  def test_passes_the_decoded_path_rather_than_the_uri
    @manager.add_bookmarks_for_print('file:///home/me/my%20notes.pdf', MARKDOWN)

    assert_equal '/home/me/my notes.pdf', @writer.deferred.first.first
  end
end
