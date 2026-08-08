# frozen_string_literal: true

require 'net/http'
require 'uri'

module Adapters
  # Fetches things over HTTP for the queue's metadata worker.
  #
  # Each method answers with the response body, or nil when the server did not
  # answer with success. Network failures raise: whether a page that cannot be
  # reached is worth a warning is the caller's decision, and the three callers
  # differ (a failed page fetch is reported, a failed favicon fetch is not).
  class HttpFetcher
    # Sites serve different markup to a browser than to a script, and the
    # metadata we are after is the browser's.
    BROWSER_USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'

    # A document the user asked to read is worth waiting longer for than
    # metadata nobody is looking at.
    DOCUMENT_USER_AGENT = 'Mozilla/5.0 (compatible; ToyBrowser/1.0)'
    DOCUMENT_OPEN_TIMEOUT_SECONDS = 10
    DOCUMENT_READ_TIMEOUT_SECONDS = 30

    # A redirect chain longer than this is treated as a document that cannot
    # be fetched. Something has to bound it: a server that redirects to itself
    # would otherwise be followed forever.
    MAX_REDIRECTS = 5

    PAGE_TIMEOUT_SECONDS = 5
    ASSET_TIMEOUT_SECONDS = 3

    # Fetches a page's HTML, announcing itself as a browser
    #
    # @param url [String] URL to fetch
    # @return [String, nil] Response body, or nil unless the response succeeded
    def fetch_page(url)
      get(url, timeout: PAGE_TIMEOUT_SECONDS, user_agent: BROWSER_USER_AGENT)
    end

    # Fetches a text document from an API endpoint
    #
    # The body is returned unparsed -- reading meaning out of it belongs to
    # Domain.
    #
    # @param url [String] URL to fetch
    # @return [String, nil] Response body, or nil unless the response succeeded
    def fetch_api(url)
      get(url, timeout: PAGE_TIMEOUT_SECONDS)
    end

    # Fetches a small binary asset, such as a favicon
    #
    # Waits less than a page fetch: the asset is an embellishment, and the
    # entry is worth saving without it.
    #
    # @param url [String] URL to fetch
    # @return [String, nil] Response body, or nil unless the response succeeded
    def fetch_asset(url)
      get(url, timeout: ASSET_TIMEOUT_SECONDS)
    end

    # Fetches a text document the user asked to read, following redirects
    #
    # The body is returned as UTF-8: a document that reaches a webview has to
    # be text, and the server's charset was already being ignored here.
    #
    # @param url [String] URL to fetch
    # @param redirects_left [Integer] Redirects still allowed to be followed
    # @return [String, nil] Response body, or nil unless the response succeeded
    def fetch_document(url, redirects_left: MAX_REDIRECTS)
      response = get_response(url, open_timeout: DOCUMENT_OPEN_TIMEOUT_SECONDS,
                                   read_timeout: DOCUMENT_READ_TIMEOUT_SECONDS,
                                   user_agent: DOCUMENT_USER_AGENT)

      case response
      when Net::HTTPSuccess
        response.body.dup.force_encoding('UTF-8')
      when Net::HTTPRedirection
        return nil if redirects_left.zero?

        fetch_document(response['location'], redirects_left: redirects_left - 1)
      end
    end

    private

    # @param url [String] URL to fetch
    # @param timeout [Integer] Open and read timeout, in seconds
    # @param user_agent [String, nil] User-Agent header to send, if any
    # @return [String, nil] Response body, or nil unless the response succeeded
    def get(url, timeout:, user_agent: nil)
      response = get_response(url, open_timeout: timeout, read_timeout: timeout, user_agent: user_agent)

      response.is_a?(Net::HTTPSuccess) ? response.body : nil
    end

    # @param url [String] URL to fetch
    # @param open_timeout [Integer] Seconds to wait for the connection
    # @param read_timeout [Integer] Seconds to wait for the response
    # @param user_agent [String, nil] User-Agent header to send, if any
    # @return [Net::HTTPResponse] Whatever the server answered
    def get_response(url, open_timeout:, read_timeout:, user_agent: nil)
      uri = URI.parse(url)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: open_timeout, read_timeout: read_timeout) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = user_agent if user_agent
        http.request(request)
      end
    end
  end
end
