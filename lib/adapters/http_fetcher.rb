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

    private

    # @param url [String] URL to fetch
    # @param timeout [Integer] Open and read timeout, in seconds
    # @param user_agent [String, nil] User-Agent header to send, if any
    # @return [String, nil] Response body, or nil unless the response succeeded
    def get(url, timeout:, user_agent: nil)
      uri = URI.parse(url)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: timeout, read_timeout: timeout) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = user_agent if user_agent
        http.request(request)
      end

      response.is_a?(Net::HTTPSuccess) ? response.body : nil
    end
  end
end
