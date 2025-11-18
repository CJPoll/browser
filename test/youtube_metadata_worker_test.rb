require_relative 'test_helper'

class YouTubeMetadataWorkerTest < Minitest::Test
  def setup
    # Create temporary database for each test
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = QueueManager.new(@temp_db_path)
    @worker = QueueMetadataWorker.new(@queue_manager)
  end

  def teardown
    # Stop worker and close database
    @worker.stop if @worker

    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      db.close unless db.closed?
    end

    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_youtube_video_detection
    # Setup: Use @worker from setup method

    # Execute: Test various URLs
    youtube_watch_urls = [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/watch?v=abc123",
      "https://m.youtube.com/watch?v=xyz789&t=10s",
    ]

    non_youtube_urls = [
      "https://www.youtube.com/watch",  # No v parameter
      "https://www.youtube.com/watch?v=",  # Empty v parameter
      "https://www.youtube.com/channel/UC1234",
      "https://www.youtube.com/playlist?list=PL1234",
      "https://example.com/watch?v=123",
      "not a url",
    ]

    # Assert: YouTube watch URLs are detected
    # Gap 2 RESOLUTION: Methods are PRIVATE - use .send(:method_name) to access in tests
    youtube_watch_urls.each do |url|
      result = @worker.send(:youtube_video?, url)
      assert result, "#{url} should be detected as YouTube video"
    end

    # Assert: Non-YouTube URLs are NOT detected
    non_youtube_urls.each do |url|
      result = @worker.send(:youtube_video?, url)
      refute result, "#{url} should NOT be detected as YouTube video"
    end
  end

  def test_extract_youtube_metadata_from_jsonld
    # Setup: Use @worker from setup method

    # Setup: Create sample HTML with JSON-LD
    html = <<~HTML
      <html>
        <head>
          <title>YouTube</title>
          <script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "VideoObject",
            "name": "Test Video Title",
            "uploadDate": "2023-10-25T14:30:00Z",
            "author": {
              "@type": "Person",
              "name": "Test Channel"
            }
          }
          </script>
        </head>
        <body></body>
      </html>
    HTML

    # Execute: Extract metadata (private method accessed via .send)
    result = @worker.send(:extract_youtube_metadata_from_jsonld, html)

    # Assert: All metadata fields are extracted correctly
    assert_not_nil result, "Should extract metadata from JSON-LD"
    assert_equal "Test Video Title", result[:title]
    assert_equal "Test Channel", result[:channel]

    # Verify date is Unix timestamp for 2023-10-25 14:30:00 UTC
    expected_timestamp = Time.parse("2023-10-25T14:30:00Z").to_i
    assert_equal expected_timestamp, result[:date]
  end

  def test_extract_youtube_metadata_jsonld_partial_data
    # Setup: HTML with JSON-LD missing channel and date
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "VideoObject",
            "name": "Title Only Video"
          }
          </script>
        </head>
      </html>
    HTML

    # Execute: Extract metadata (private method accessed via .send)
    result = @worker.send(:extract_youtube_metadata_from_jsonld, html)

    # Assert: Partial data is extracted
    assert_not_nil result, "Should extract partial metadata"
    assert_equal "Title Only Video", result[:title]
    assert_nil result[:channel], "Channel should be nil when not present"
    assert_nil result[:date], "Date should be nil when not present"
  end

  def test_oembed_api_fallback
    # Execute: Fetch metadata from oEmbed API
    # NOTE: This is an integration test that makes a real network request
    # Use a known stable YouTube video (Rick Astley - Never Gonna Give You Up)
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    result = @worker.send(:fetch_youtube_oembed_metadata, url)

    # Assert: Metadata is fetched
    # Skip test if network unavailable (don't fail on CI without internet)
    skip "Network unavailable" unless result

    assert_not_nil result, "Should fetch metadata from oEmbed API"
    assert_not_nil result[:title], "Should have title"
    assert_not_nil result[:channel], "Should have channel (author_name)"
    assert_nil result[:date], "oEmbed API does not provide publish date"

    # Verify title contains expected keywords (may change over time)
    assert_match(/Rick Astley/i, result[:title])
  end

  def test_oembed_api_fallback_mocked
    # Setup: Mock HTTP response
    url = "https://www.youtube.com/watch?v=test123"
    mock_response_body = {
      title: "Test Video",
      author_name: "Test Channel"
    }.to_json

    # Mock Net::HTTP.start
    mock_http = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    mock_response.expect(:is_a?, true, [Net::HTTPSuccess])
    mock_response.expect(:body, mock_response_body)

    mock_http.expect(:request, mock_response, [Object])

    Net::HTTP.stub(:start, -> (*args, &block) { block.call(mock_http) }) do
      # Execute: Fetch metadata (private method accessed via .send)
      result = @worker.send(:fetch_youtube_oembed_metadata, url)

      # Assert: Metadata is parsed correctly
      assert_not_nil result
      assert_equal "Test Video", result[:title]
      assert_equal "Test Channel", result[:channel]
      assert_nil result[:date]
    end
  end

  def test_graceful_degradation_on_metadata_failure
    # Setup: HTML with invalid JSON-LD and no oEmbed available
    html_with_invalid_json = <<~HTML
      <html>
        <head>
          <title>Fallback Title from HTML</title>
          <script type="application/ld+json">
            { invalid json here
          </script>
        </head>
        <body></body>
      </html>
    HTML

    # Execute: Extract metadata from JSON-LD (should fail gracefully)
    result = @worker.send(:extract_youtube_metadata_from_jsonld, html_with_invalid_json)

    # Assert: Returns nil without crashing
    assert_nil result, "Should return nil when JSON-LD parsing fails"

    # Execute: Extract basic title (fallback)
    title = @worker.send(:extract_title_from_html, html_with_invalid_json)

    # Assert: Fallback title extraction still works
    assert_equal "Fallback Title from HTML", title
  end
end
