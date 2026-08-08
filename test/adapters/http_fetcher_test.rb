require 'minitest/autorun'
require 'webmock/minitest'
require_relative '../../lib/adapters/http_fetcher'

class AdaptersHttpFetcherTest < Minitest::Test
  PAGE_URL = 'https://example.com/article'
  API_URL = 'https://www.youtube.com/oembed?url=x&format=json'
  ASSET_URL = 'https://example.com/favicon.ico'
  DOCUMENT_URL = 'https://example.com/README.md'

  def setup
    @fetcher = Adapters::HttpFetcher.new
  end

  def test_returns_the_page_body
    stub_request(:get, PAGE_URL).to_return(status: 200, body: '<html>hi</html>')

    assert_equal '<html>hi</html>', @fetcher.fetch_page(PAGE_URL)
  end

  def test_announces_itself_as_a_browser_when_fetching_a_page
    stub = stub_request(:get, PAGE_URL)
           .with(headers: { 'User-Agent' => Adapters::HttpFetcher::BROWSER_USER_AGENT })
           .to_return(status: 200, body: 'ok')

    @fetcher.fetch_page(PAGE_URL)

    assert_requested stub
  end

  def test_a_page_that_is_not_there_fetches_as_nothing
    stub_request(:get, PAGE_URL).to_return(status: 404, body: 'Not Found')

    assert_nil @fetcher.fetch_page(PAGE_URL)
  end

  def test_a_redirect_is_not_followed
    stub_request(:get, PAGE_URL).to_return(status: 302, headers: { 'Location' => 'https://example.com/moved' })

    assert_nil @fetcher.fetch_page(PAGE_URL)
  end

  def test_returns_an_api_body_unparsed
    stub_request(:get, API_URL).to_return(status: 200, body: '{"title": "T"}')

    assert_equal '{"title": "T"}', @fetcher.fetch_api(API_URL)
  end

  def test_an_api_error_fetches_as_nothing
    stub_request(:get, API_URL).to_return(status: 401, body: 'nope')

    assert_nil @fetcher.fetch_api(API_URL)
  end

  def test_returns_asset_bytes
    stub_request(:get, ASSET_URL).to_return(status: 200, body: "\x89PNG\r\n")

    assert_equal "\x89PNG\r\n", @fetcher.fetch_asset(ASSET_URL)
  end

  def test_a_missing_asset_fetches_as_nothing
    stub_request(:get, ASSET_URL).to_return(status: 404, body: '')

    assert_nil @fetcher.fetch_asset(ASSET_URL)
  end

  def test_fetches_over_plain_http_when_the_url_says_so
    stub_request(:get, 'http://example.com/page').to_return(status: 200, body: 'plain')

    assert_equal 'plain', @fetcher.fetch_page('http://example.com/page')
  end

  # The caller decides whether an unreachable host is worth reporting, so the
  # failure has to reach it rather than being swallowed here.
  def test_a_network_failure_reaches_the_caller
    stub_request(:get, PAGE_URL).to_raise(SocketError.new('getaddrinfo: Name or service not known'))

    assert_raises(SocketError) { @fetcher.fetch_page(PAGE_URL) }
  end

  # === Documents the user asked to read ===

  def test_returns_the_document_body
    stub_request(:get, DOCUMENT_URL).to_return(status: 200, body: "# Title\n")

    assert_equal "# Title\n", @fetcher.fetch_document(DOCUMENT_URL)
  end

  def test_reads_a_document_as_utf8
    stub_request(:get, DOCUMENT_URL).to_return(status: 200, body: 'Café'.dup.force_encoding('ASCII-8BIT'))

    body = @fetcher.fetch_document(DOCUMENT_URL)

    assert_equal Encoding::UTF_8, body.encoding
    assert_equal 'Café', body
  end

  def test_announces_itself_as_the_browser_when_fetching_a_document
    stub = stub_request(:get, DOCUMENT_URL)
           .with(headers: { 'User-Agent' => Adapters::HttpFetcher::DOCUMENT_USER_AGENT })
           .to_return(status: 200, body: 'ok')

    @fetcher.fetch_document(DOCUMENT_URL)

    assert_requested stub
  end

  def test_a_document_that_is_not_there_fetches_as_nothing
    stub_request(:get, DOCUMENT_URL).to_return(status: 404, body: 'Not Found')

    assert_nil @fetcher.fetch_document(DOCUMENT_URL)
  end

  def test_follows_a_redirect_to_the_document
    stub_request(:get, DOCUMENT_URL)
      .to_return(status: 302, headers: { 'Location' => 'https://example.com/moved/README.md' })
    stub_request(:get, 'https://example.com/moved/README.md').to_return(status: 200, body: 'moved here')

    assert_equal 'moved here', @fetcher.fetch_document(DOCUMENT_URL)
  end

  def test_follows_a_chain_of_redirects
    (0...Adapters::HttpFetcher::MAX_REDIRECTS).each do |hop|
      stub_request(:get, "https://example.com/hop#{hop}.md")
        .to_return(status: 302, headers: { 'Location' => "https://example.com/hop#{hop + 1}.md" })
    end
    stub_request(:get, "https://example.com/hop#{Adapters::HttpFetcher::MAX_REDIRECTS}.md")
      .to_return(status: 200, body: 'arrived')

    assert_equal 'arrived', @fetcher.fetch_document('https://example.com/hop0.md')
  end

  # A server that redirects to itself would otherwise be followed forever.
  def test_a_redirect_loop_fetches_as_nothing
    stub_request(:get, DOCUMENT_URL).to_return(status: 302, headers: { 'Location' => DOCUMENT_URL })

    assert_nil @fetcher.fetch_document(DOCUMENT_URL)
  end
end
