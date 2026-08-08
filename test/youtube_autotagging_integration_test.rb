require_relative 'test_helper'
require 'webmock/minitest'

class YouTubeAutoTaggingIntegrationTest < Minitest::Test
  def setup
    # Create temporary database
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)
    @worker = QueueMetadataWorker.new(@queue_manager)
  end

  def teardown
    # Stop worker and close database
    @worker.stop if @worker

    if @queue_manager
      @queue_manager.close
    end

    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_youtube_video_auto_tagging
    # Setup: Add YouTube video to queue
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    result = @queue_manager.add(url, nil, nil)
    assert_equal :added, result

    entry = @queue_manager.find_by_url(url)
    assert_not_nil entry

    # Setup: Mock HTTP response with JSON-LD
    html_with_jsonld = <<~HTML
      <html>
        <head>
          <title>Test Video - YouTube</title>
          <script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "VideoObject",
            "name": "Rick Astley - Never Gonna Give You Up",
            "uploadDate": "2009-10-25T07:00:00Z",
            "author": {
              "@type": "Person",
              "name": "Rick Astley"
            }
          }
          </script>
        </head>
        <body></body>
      </html>
    HTML

    stub_request(:get, url)
      .to_return(status: 200, body: html_with_jsonld, headers: {})

    # Also stub favicon request to avoid real network call
    stub_request(:get, "https://www.youtube.com/favicon.ico")
      .to_return(status: 404, body: "", headers: {})

    # Execute: Enqueue metadata fetch
    @worker.enqueue(entry.id, url)

    # Gap 7 RESOLUTION: Polling loop pattern confirmation
    # CLAUDE.md hard rule states:
    # - ❌ BAD: Process.sleep(2000); assert something (arbitrary delay)
    # - ✅ OK: Polling loops with condition checking and timeout
    #
    # This pattern uses a while loop with condition checking (tags.length >= 2)
    # and timeout protection (max_iterations = 50 * 0.1s = 5 seconds total).
    # Each iteration checks the condition and breaks early if satisfied.
    # This is ACCEPTABLE under the hard rule - it's a polling loop, not arbitrary sleep.
    #
    # Wait for worker to process (use polling loop, not arbitrary Process.sleep)
    # Maximum wait: 5 seconds
    max_iterations = 50
    iteration = 0
    tags = []

    while iteration < max_iterations
      tags = @queue_manager.tags_for_entry(entry.id)
      break if tags.length >= 2  # Expecting YouTube + channel tag
      sleep 0.1  # Short sleep inside condition-checking loop (acceptable)
      iteration += 1
    end

    # Assert: "YouTube" tag is assigned
    tag_names = tags.map { |tag| tag.name }
    assert_includes tag_names, "YouTube", "Should auto-assign YouTube tag"

    # Assert: Channel tag is assigned
    assert_includes tag_names, "Rick Astley", "Should auto-assign channel tag"

    # Assert: Publish date is stored
    updated_entry = @queue_manager.find_by_id(entry.id)
    assert_not_nil updated_entry.published_at, "Should store publish date"

    expected_timestamp = Time.parse("2009-10-25T07:00:00Z")
    assert_equal expected_timestamp, updated_entry.published_at
  end
end
