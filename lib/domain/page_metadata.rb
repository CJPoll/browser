# frozen_string_literal: true

require 'uri'
require 'cgi'
require 'json'
require 'time'

module Domain
  # Reads the metadata a queue entry needs out of a page that has already been
  # fetched: its title, its favicon location, and -- for YouTube videos -- the
  # title, channel and publish date the site publishes as structured data.
  #
  # Everything here is parsing. Fetching the page belongs to
  # `Adapters::HttpFetcher`; deciding what to do with the result belongs to
  # `Managers::QueueMetadataWorker`.
  module PageMetadata
    YOUTUBE_HOSTS = ['www.youtube.com', 'youtube.com', 'm.youtube.com'].freeze
    OEMBED_ENDPOINT = 'https://www.youtube.com/oembed'
    CONVENTIONAL_FAVICON_PATH = '/favicon.ico'

    TITLE_PATTERN = /<title[^>]*>(.*?)<\/title>/im
    FAVICON_PATTERN = /<link[^>]*rel=["'](?:shortcut )?icon["'][^>]*href=["']([^"']+)["']/im
    JSON_LD_PATTERN = /<script[^>]*type=["']application\/ld\+json["'][^>]*>(.*?)<\/script>/im

    module_function

    # Is this URL a YouTube video page?
    #
    # WART (preserved): `youtu.be` short links are not recognised -- only the
    # three full YouTube hosts are.
    #
    # @param url [String] URL to classify
    # @return [Boolean] True for a /watch?v=<id> or /shorts/<id> URL
    def youtube_video?(url)
      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError
        return false
      end

      return false unless YOUTUBE_HOSTS.include?(uri.host)

      if uri.path == '/watch'
        return false unless uri.query

        params = CGI.parse(uri.query)
        return params.key?('v') && !params['v'].empty? && !params['v'].first.empty?
      end

      return !uri.path.sub('/shorts/', '').empty? if uri.path.start_with?('/shorts/')

      false
    end

    # The oEmbed endpoint that describes a YouTube video
    #
    # @param video_url [String] YouTube video URL
    # @return [String] URL of the JSON oEmbed document
    def oembed_url(video_url)
      "#{OEMBED_ENDPOINT}?url=#{CGI.escape(video_url)}&format=json"
    end

    # The page's title
    #
    # A page that declares no encoding may still be Latin-1; a title that is
    # not valid UTF-8 is re-read that way rather than dropped.
    #
    # @param html [String] Page HTML
    # @return [String, nil] Title, or nil if the page has no <title>
    def title_from_html(html)
      match = html.match(TITLE_PATTERN)
      return nil unless match

      title = match[1].strip.dup.force_encoding('UTF-8')
      unless title.valid_encoding?
        title = title.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
      end

      CGI.unescapeHTML(title)
    end

    # Where the page's favicon lives
    #
    # Falls back to the conventional `/favicon.ico` when the page declares no
    # icon link, so the caller always has somewhere to look.
    #
    # WART (preserved): the `href` attribute must follow `rel` in the tag; a
    # `<link href="..." rel="icon">` is not matched.
    #
    # @param html [String] Page HTML
    # @param base_uri [URI] URI the page was fetched from, for relative hrefs
    # @return [String] Absolute favicon URL
    def favicon_url(html, base_uri)
      match = html.match(FAVICON_PATTERN)
      return "#{base_uri.scheme}://#{base_uri.host}#{CONVENTIONAL_FAVICON_PATH}" unless match

      href = match[1]

      if href.start_with?('http')
        href
      elsif href.start_with?('//')
        "#{base_uri.scheme}:#{href}"
      elsif href.start_with?('/')
        "#{base_uri.scheme}://#{base_uri.host}#{href}"
      else
        "#{base_uri.scheme}://#{base_uri.host}/#{href}"
      end
    end

    # Video metadata from the page's JSON-LD structured data
    #
    # YouTube embeds a schema.org VideoObject in the page; it carries the
    # title and publish date but not always the channel name.
    #
    # @param html [String] Page HTML
    # @return [Hash, nil] `{title:, channel:, date:}` (date is a Unix
    #   timestamp), or nil when no VideoObject carries any of them
    def youtube_metadata_from_jsonld(html)
      html.scan(JSON_LD_PATTERN).each do |script_content|
        begin
          data = JSON.parse(script_content.first)
        rescue JSON::ParserError
          next # A page may carry other, malformed scripts; keep looking
        end

        next unless data['@type'] == 'VideoObject'

        metadata = video_object_metadata(data)
        return metadata if metadata
      end

      nil
    end

    # Video metadata from a YouTube oEmbed response body
    #
    # oEmbed is the only source that names the channel (`author_name`).
    #
    # Raises `JSON::ParserError` on a malformed body: an unusable response is
    # worth reporting, and the caller decides how.
    #
    # @param body [String] JSON response body
    # @return [Hash, nil] `{title:, channel:, date: nil}`, or nil when the
    #   response names neither
    def youtube_metadata_from_oembed(body)
      data = JSON.parse(body)

      title = data['title']
      channel = data['author_name']
      return nil unless title || channel

      { title: title, channel: channel, date: nil }
    end

    # @param data [Hash] Parsed VideoObject
    # @return [Hash, nil] Metadata, or nil if it carries none of the fields
    def video_object_metadata(data)
      title = data['name'] || data['headline']

      channel = data['author'] || data['channelName']
      channel = channel['name'] if channel.is_a?(Hash)

      date_unix = parse_upload_date(data['uploadDate'] || data['datePublished'])

      return nil unless title || channel || date_unix

      { title: title, channel: channel, date: date_unix }
    end
    private_class_method :video_object_metadata

    # @param date_str [String, nil] ISO 8601 date
    # @return [Integer, nil] Unix timestamp, or nil if absent or unparseable
    def parse_upload_date(date_str)
      return nil unless date_str

      begin
        Time.parse(date_str).to_i
      rescue ArgumentError
        nil
      end
    end
    private_class_method :parse_upload_date
  end
end
