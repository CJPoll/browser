require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/adapters/content_fetcher'

class AdaptersContentFetcherTest < Minitest::Test
  # Stands in for Adapters::HttpFetcher: records what it was asked for and
  # answers what the test told it to.
  class MockHttpFetcher
    attr_reader :requested

    def initialize(body: nil, error: nil)
      @body = body
      @error = error
      @requested = []
    end

    def fetch_document(url)
      @requested << url
      raise @error if @error

      @body
    end
  end

  def setup
    @http = MockHttpFetcher.new(body: '# Remote')
    @fetcher = Adapters::ContentFetcher.new(http_fetcher: @http)
    @dir = Dir.mktmpdir('content-fetcher-test')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # === Local files ===

  def test_reads_a_local_file
    path = write_file('notes.md', "# Local\n")

    assert_equal "# Local\n", @fetcher.fetch("file://#{path}")
  end

  def test_reads_a_file_whose_name_was_escaped_into_the_url
    path = write_file('my notes.md', 'spaced')

    assert_equal 'spaced', @fetcher.fetch("file://#{path.sub(' ', '%20')}")
  end

  def test_reads_a_file_as_utf8
    path = write_file('accents.md', "# Café\n")

    content = @fetcher.fetch("file://#{path}")

    assert_equal Encoding::UTF_8, content.encoding
    assert_includes content, 'Café'
  end

  def test_a_file_that_is_not_there_fetches_as_nothing
    assert_nil @fetcher.fetch("file://#{@dir}/absent.md")
  end

  def test_does_not_go_to_the_network_for_a_local_file
    write_file('notes.md', 'local')

    @fetcher.fetch("file://#{@dir}/notes.md")

    assert_empty @http.requested
  end

  # === Remote documents ===

  def test_fetches_a_remote_document_over_https
    assert_equal '# Remote', @fetcher.fetch('https://example.com/README.md')
    assert_equal ['https://example.com/README.md'], @http.requested
  end

  def test_fetches_a_remote_document_over_plain_http
    assert_equal '# Remote', @fetcher.fetch('http://example.com/README.md')
  end

  def test_a_document_the_server_will_not_give_fetches_as_nothing
    fetcher = Adapters::ContentFetcher.new(http_fetcher: MockHttpFetcher.new(body: nil))

    assert_nil fetcher.fetch('https://example.com/gone.md')
  end

  # The caller decides whether an unreachable host is worth reporting, so the
  # failure has to reach it rather than being swallowed here.
  def test_a_network_failure_reaches_the_caller
    fetcher = Adapters::ContentFetcher.new(http_fetcher: MockHttpFetcher.new(error: SocketError.new('no dns')))

    assert_raises(SocketError) { fetcher.fetch('https://example.com/README.md') }
  end

  # === Everything else ===

  def test_a_scheme_it_cannot_fetch_fetches_as_nothing
    assert_nil @fetcher.fetch('about:blank')
    assert_nil @fetcher.fetch('data:text/plain,hello')
    assert_empty @http.requested
  end

  private

  def write_file(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end
end
