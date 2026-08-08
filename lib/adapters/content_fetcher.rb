# frozen_string_literal: true

require 'uri'
require 'cgi'
require_relative 'http_fetcher'

module Adapters
  # Fetches the bytes behind a URL the browser wants to render itself, whether
  # they live on disk or on a server.
  #
  # Answers nil when there is nothing to fetch (no such file, a server that
  # refused, a scheme this cannot read) and raises when the attempt itself
  # failed -- whether that is worth reporting is the manager's decision.
  class ContentFetcher
    FETCHABLE_SCHEMES = %w[file http https].freeze

    # @param http_fetcher [Adapters::HttpFetcher] Performs the remote fetches
    def initialize(http_fetcher: HttpFetcher.new)
      @http_fetcher = http_fetcher
    end

    # @param url [String] URL to fetch
    # @return [String, nil] Content, or nil when there is none to be had
    def fetch(url)
      uri = URI.parse(url)

      case uri.scheme
      when 'file' then read_file(CGI.unescape(uri.path.to_s))
      when 'http', 'https' then @http_fetcher.fetch_document(url)
      end
    end

    private

    # @param path [String] Absolute path
    # @return [String, nil] File content, or nil when there is no such file
    def read_file(path)
      return nil unless File.exist?(path)

      File.read(path, encoding: 'UTF-8')
    end
  end
end
