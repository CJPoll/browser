require 'minitest/autorun'
require_relative '../../lib/managers/external_opener'

class ManagersExternalOpenerTest < Minitest::Test
  class MockUriOpener
    attr_reader :opened

    def initialize(result: true)
      @opened = []
      @result = result
    end

    def open(target)
      @opened << target
      @result
    end
  end

  def setup
    @uri_opener = MockUriOpener.new
    @opener = Managers::ExternalOpener.new(uri_opener: @uri_opener)
  end

  # === URIs belonging to another application ===

  def test_opens_a_uri_with_the_desktop_handler
    @opener.open_uri('spotify://track/123')

    assert_equal ['spotify://track/123'], @uri_opener.opened
  end

  def test_reports_whether_the_handler_was_launched
    assert_equal true, @opener.open_uri('spotify://track/123')
  end

  def test_reports_failure_from_the_desktop_handler
    opener = Managers::ExternalOpener.new(uri_opener: MockUriOpener.new(result: false))

    assert_equal false, opener.open_uri('spotify://track/123')
  end

  def test_does_not_open_a_missing_uri
    assert_equal false, @opener.open_uri(nil)
    assert_empty @uri_opener.opened
  end

  # === Downloaded files ===

  def test_opens_a_downloaded_file
    @opener.open_path('/home/user/Downloads/report.pdf')

    assert_equal ['/home/user/Downloads/report.pdf'], @uri_opener.opened
  end

  def test_does_not_open_a_missing_path
    assert_equal false, @opener.open_path(nil)
    assert_empty @uri_opener.opened
  end

  # === Revealing a file in the file manager ===

  def test_opens_the_directory_holding_a_file
    @opener.open_containing_directory('/home/user/Downloads/report.pdf')

    assert_equal ['/home/user/Downloads'], @uri_opener.opened
  end

  def test_opens_the_working_directory_for_a_bare_filename
    @opener.open_containing_directory('report.pdf')

    assert_equal ['.'], @uri_opener.opened
  end

  def test_does_not_reveal_a_missing_path
    assert_equal false, @opener.open_containing_directory(nil)
    assert_empty @uri_opener.opened
  end

  def test_does_not_reveal_a_blank_path
    assert_equal false, @opener.open_containing_directory('  ')
    assert_empty @uri_opener.opened
  end
end
