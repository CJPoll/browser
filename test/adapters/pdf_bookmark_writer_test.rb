require_relative '../test_helper'
require_relative '../../lib/adapters/pdf_bookmark_writer'

# Tests for Adapters::PdfBookmarkWriter
#
# The in-process path is HexaPDF's work; what is tested here is the guard
# clauses around it and -- the reason this adapter exists -- that the
# background path passes paths as arguments rather than building code out of
# them.
class PdfBookmarkWriterTest < Minitest::Test
  # Records what was launched instead of starting a process
  class RecordingLauncher
    attr_reader :argv, :options, :detached_count

    def initialize
      @detached_count = 0
    end

    def launch_detached(*argv, **options)
      @argv = argv
      @options = options
      @detached_count += 1
      4242
    end
  end

  MARKDOWN = "# Chapter\n\n## Section\n"

  def setup
    @launcher = RecordingLauncher.new
    @written_markdown = nil
    @temp_writer = lambda do |markdown|
      @written_markdown = markdown
      '/tmp/markdown-under-test.md'
    end
    @writer = Adapters::PdfBookmarkWriter.new(
      process_launcher: @launcher,
      temp_file_writer: @temp_writer
    )
  end

  # ============================================================
  # add_bookmarks (in process)
  # ============================================================

  def test_reports_failure_when_the_pdf_does_not_exist
    refute @writer.add_bookmarks('/nonexistent/nowhere.pdf', MARKDOWN)
  end

  def test_reports_failure_when_the_markdown_has_no_headings
    with_temp_file('.pdf') do |path|
      refute @writer.add_bookmarks(path, "no headings here\n")
    end
  end

  def test_reports_failure_when_there_is_no_markdown_at_all
    with_temp_file('.pdf') do |path|
      refute @writer.add_bookmarks(path, nil)
    end
  end

  def test_reports_failure_rather_than_raising_on_a_file_that_is_not_a_pdf
    with_temp_file('.pdf') do |path|
      File.write(path, 'this is not a PDF')

      refute @writer.add_bookmarks(path, MARKDOWN)
    end
  end

  # ============================================================
  # add_bookmarks_later (background process)
  # ============================================================

  def test_launches_the_bookmark_script_detached
    @writer.add_bookmarks_later('/home/me/notes.pdf', MARKDOWN)

    assert_equal 1, @launcher.detached_count
    assert_equal %w[bundle exec ruby], @launcher.argv.first(3)
    assert_equal Adapters::PdfBookmarkWriter::BACKGROUND_SCRIPT, @launcher.argv[3]
  end

  def test_the_background_script_exists_where_the_adapter_says_it_does
    assert File.exist?(Adapters::PdfBookmarkWriter::BACKGROUND_SCRIPT),
           'the adapter names a script that is not in the repository'
  end

  def test_passes_the_pdf_and_markdown_paths_as_separate_arguments
    @writer.add_bookmarks_later('/home/me/notes.pdf', MARKDOWN)

    assert_equal ['/home/me/notes.pdf', '/tmp/markdown-under-test.md'], @launcher.argv.last(2)
  end

  def test_writes_the_markdown_out_for_the_background_process_to_read
    @writer.add_bookmarks_later('/home/me/notes.pdf', MARKDOWN)

    assert_equal MARKDOWN, @written_markdown
  end

  def test_runs_the_background_process_from_the_project_so_bundler_finds_the_gemfile
    @writer.add_bookmarks_later('/home/me/notes.pdf', MARKDOWN)

    assert_equal Adapters::PdfBookmarkWriter::PROJECT_ROOT, @launcher.options[:chdir]
    assert File.exist?(File.join(@launcher.options[:chdir], 'Gemfile'))
  end

  def test_returns_the_process_id
    assert_equal 4242, @writer.add_bookmarks_later('/home/me/notes.pdf', MARKDOWN)
  end

  # The reason the heredoc this replaced had to go: the PDF path comes from a
  # print dialog, so a filename can contain quotes, backslashes and shell
  # syntax. As an argument it is data; interpolated into source it was code.
  def test_a_hostile_filename_stays_a_single_argument
    hostile = "/tmp/'; system('rm -rf ~'); '.pdf"

    @writer.add_bookmarks_later(hostile, MARKDOWN)

    assert_includes @launcher.argv, hostile
    assert_equal 6, @launcher.argv.size
  end

  private

  def with_temp_file(extension)
    file = Tempfile.new(['pdf-bookmark-writer', extension])
    file.close
    yield file.path
  ensure
    file&.unlink
  end
end
