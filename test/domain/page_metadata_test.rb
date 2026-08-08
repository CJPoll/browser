require 'minitest/autorun'
require 'uri'
require_relative '../../lib/domain/page_metadata'

class DomainPageMetadataTest < Minitest::Test
  BASE_URI = URI.parse('https://example.com/articles/one')

  # --- youtube_video? ------------------------------------------------------

  def test_recognises_a_watch_url_on_every_youtube_host
    assert Domain::PageMetadata.youtube_video?('https://www.youtube.com/watch?v=dQw4w9WgXcQ')
    assert Domain::PageMetadata.youtube_video?('https://youtube.com/watch?v=abc123')
    assert Domain::PageMetadata.youtube_video?('https://m.youtube.com/watch?v=xyz789&t=10s')
  end

  def test_recognises_a_shorts_url
    assert Domain::PageMetadata.youtube_video?('https://www.youtube.com/shorts/abc123')
  end

  def test_a_watch_url_without_a_video_id_is_not_a_video
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/watch')
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/watch?v=')
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/watch?t=10s')
  end

  def test_a_shorts_url_without_an_id_is_not_a_video
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/shorts/')
  end

  def test_other_youtube_pages_are_not_videos
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/channel/UC1234')
    refute Domain::PageMetadata.youtube_video?('https://www.youtube.com/playlist?list=PL1234')
  end

  def test_a_watch_url_on_another_host_is_not_a_video
    refute Domain::PageMetadata.youtube_video?('https://example.com/watch?v=123')
  end

  def test_unparseable_input_is_not_a_video
    refute Domain::PageMetadata.youtube_video?('not a url')
    refute Domain::PageMetadata.youtube_video?('http://[bad')
  end

  # WART (preserved): youtu.be short links are not recognised, so they get no
  # YouTube tag and no channel tag. Only the three full hosts are matched.
  def test_wart_youtu_be_short_links_are_not_recognised
    refute Domain::PageMetadata.youtube_video?('https://youtu.be/dQw4w9WgXcQ')
  end

  # --- oembed_url ----------------------------------------------------------

  def test_builds_the_oembed_endpoint_with_the_video_url_escaped
    url = Domain::PageMetadata.oembed_url('https://www.youtube.com/watch?v=dQw4w9WgXcQ')

    assert_equal 'https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2F' \
                 'watch%3Fv%3DdQw4w9WgXcQ&format=json', url
  end

  # --- title_from_html -----------------------------------------------------

  def test_extracts_and_strips_the_title
    assert_equal 'Hello', Domain::PageMetadata.title_from_html("<html><title>  Hello  </title></html>")
  end

  def test_extracts_a_title_across_lines_and_attributes
    html = "<head>\n<title data-x='1'>Two\nLines</title>\n</head>"

    assert_equal "Two\nLines", Domain::PageMetadata.title_from_html(html)
  end

  def test_unescapes_html_entities_in_the_title
    assert_equal 'Tom & Jerry <3',
                 Domain::PageMetadata.title_from_html('<title>Tom &amp; Jerry &lt;3</title>')
  end

  def test_returns_nil_when_there_is_no_title
    assert_nil Domain::PageMetadata.title_from_html('<html><body>no title</body></html>')
  end

  def test_recovers_a_latin1_title_that_is_not_valid_utf8
    html = "<title>Caf\xE9</title>".dup.force_encoding('ASCII-8BIT')

    title = Domain::PageMetadata.title_from_html(html)

    assert_equal 'Café', title
    assert_equal Encoding::UTF_8, title.encoding
  end

  # --- favicon_url ---------------------------------------------------------

  def test_uses_an_absolute_favicon_href_as_is
    html = %(<link rel="icon" href="https://cdn.example.com/icon.png">)

    assert_equal 'https://cdn.example.com/icon.png',
                 Domain::PageMetadata.favicon_url(html, BASE_URI)
  end

  def test_resolves_a_protocol_relative_favicon_href
    html = %(<link rel="icon" href="//cdn.example.com/icon.png">)

    assert_equal 'https://cdn.example.com/icon.png',
                 Domain::PageMetadata.favicon_url(html, BASE_URI)
  end

  def test_resolves_a_root_relative_favicon_href
    html = %(<link rel="shortcut icon" href="/static/icon.png">)

    assert_equal 'https://example.com/static/icon.png',
                 Domain::PageMetadata.favicon_url(html, BASE_URI)
  end

  def test_resolves_a_relative_favicon_href_against_the_host_root
    html = %(<link rel="icon" href="icon.png">)

    assert_equal 'https://example.com/icon.png',
                 Domain::PageMetadata.favicon_url(html, BASE_URI)
  end

  def test_falls_back_to_the_conventional_favicon_path
    assert_equal 'https://example.com/favicon.ico',
                 Domain::PageMetadata.favicon_url('<html></html>', BASE_URI)
  end

  # WART (preserved): the href must follow the rel attribute in the tag. A
  # `<link href="..." rel="icon">` is missed and the conventional path is used.
  def test_wart_href_before_rel_is_not_matched
    html = %(<link href="/static/icon.png" rel="icon">)

    assert_equal 'https://example.com/favicon.ico',
                 Domain::PageMetadata.favicon_url(html, BASE_URI)
  end

  # --- youtube_metadata_from_jsonld ----------------------------------------

  def jsonld(body)
    %(<html><head><script type="application/ld+json">#{body}</script></head></html>)
  end

  def test_extracts_title_channel_and_date_from_a_video_object
    html = jsonld(<<~JSON)
      {
        "@context": "https://schema.org",
        "@type": "VideoObject",
        "name": "Test Video Title",
        "uploadDate": "2023-10-25T14:30:00Z",
        "author": { "@type": "Person", "name": "Test Channel" }
      }
    JSON

    result = Domain::PageMetadata.youtube_metadata_from_jsonld(html)

    assert_equal 'Test Video Title', result[:title]
    assert_equal 'Test Channel', result[:channel]
    assert_equal Time.parse('2023-10-25T14:30:00Z').to_i, result[:date]
  end

  def test_accepts_a_plain_string_author
    html = jsonld('{"@type": "VideoObject", "name": "T", "author": "A Channel"}')

    assert_equal 'A Channel', Domain::PageMetadata.youtube_metadata_from_jsonld(html)[:channel]
  end

  def test_falls_back_to_headline_channel_name_and_date_published
    html = jsonld(<<~JSON)
      {
        "@type": "VideoObject",
        "headline": "Headline Title",
        "channelName": "Channel Name",
        "datePublished": "2020-01-02T00:00:00Z"
      }
    JSON

    result = Domain::PageMetadata.youtube_metadata_from_jsonld(html)

    assert_equal 'Headline Title', result[:title]
    assert_equal 'Channel Name', result[:channel]
    assert_equal Time.parse('2020-01-02T00:00:00Z').to_i, result[:date]
  end

  def test_returns_partial_metadata_when_only_a_title_is_present
    result = Domain::PageMetadata.youtube_metadata_from_jsonld(
      jsonld('{"@type": "VideoObject", "name": "Title Only Video"}')
    )

    assert_equal 'Title Only Video', result[:title]
    assert_nil result[:channel]
    assert_nil result[:date]
  end

  def test_an_unparseable_upload_date_leaves_the_date_empty
    result = Domain::PageMetadata.youtube_metadata_from_jsonld(
      jsonld('{"@type": "VideoObject", "name": "T", "uploadDate": "last tuesday"}')
    )

    assert_equal 'T', result[:title]
    assert_nil result[:date]
  end

  def test_skips_schemas_that_are_not_video_objects
    html = jsonld('{"@type": "BreadcrumbList", "name": "Not a video"}')

    assert_nil Domain::PageMetadata.youtube_metadata_from_jsonld(html)
  end

  def test_skips_invalid_json_and_keeps_looking
    html = jsonld('{ invalid json here') +
           jsonld('{"@type": "VideoObject", "name": "Second Script"}')

    assert_equal 'Second Script', Domain::PageMetadata.youtube_metadata_from_jsonld(html)[:title]
  end

  def test_returns_nil_when_the_video_object_carries_none_of_the_fields
    assert_nil Domain::PageMetadata.youtube_metadata_from_jsonld(
      jsonld('{"@type": "VideoObject", "duration": "PT2M"}')
    )
  end

  def test_returns_nil_when_there_is_no_json_ld_at_all
    assert_nil Domain::PageMetadata.youtube_metadata_from_jsonld('<html><body>hi</body></html>')
  end

  # --- youtube_metadata_from_oembed ----------------------------------------

  def test_reads_title_and_channel_from_an_oembed_response
    body = '{"title": "Test Video", "author_name": "Test Channel"}'

    result = Domain::PageMetadata.youtube_metadata_from_oembed(body)

    assert_equal 'Test Video', result[:title]
    assert_equal 'Test Channel', result[:channel]
    assert_nil result[:date], 'the oEmbed API does not report a publish date'
  end

  def test_returns_nil_when_the_oembed_response_names_neither
    assert_nil Domain::PageMetadata.youtube_metadata_from_oembed('{"type": "video"}')
  end

  def test_malformed_oembed_json_raises_for_the_caller_to_report
    assert_raises(JSON::ParserError) do
      Domain::PageMetadata.youtube_metadata_from_oembed('{ not json')
    end
  end
end
