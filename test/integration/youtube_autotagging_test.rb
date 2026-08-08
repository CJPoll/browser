require 'minitest/autorun'
require 'fileutils'
require 'tempfile'
require 'webmock/minitest'
require_relative '../../lib/managers/queue_manager'
require_relative '../../lib/managers/queue_metadata_worker'
require_relative '../../lib/repositories/queue_database'

# Integration test for the queue metadata flow without mocks:
# HttpFetcher <-> QueueMetadataWorker <-> Domain <-> QueueManager <-> SQLite.
# Only the network itself is stubbed.
class YouTubeAutoTaggingTest < Minitest::Test
  VIDEO_URL = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
  UPLOAD_DATE = '2009-10-25T07:00:00Z'

  VIDEO_HTML = <<~HTML.freeze
    <html>
      <head>
        <title>Test Video - YouTube</title>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "VideoObject",
          "name": "Rick Astley - Never Gonna Give You Up",
          "uploadDate": "#{UPLOAD_DATE}",
          "author": { "@type": "Person", "name": "Rick Astley" }
        }
        </script>
      </head>
      <body></body>
    </html>
  HTML

  def setup
    @temp_db = Tempfile.new(['queue', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = Managers::QueueManager.new(
      database: Repositories::QueueDatabase.new(db_path: @temp_db_path)
    )
    @worker = Managers::QueueMetadataWorker.new(@queue_manager)
  end

  def teardown
    @worker&.stop
    @queue_manager&.close
    FileUtils.rm_f(@temp_db_path)
  end

  def test_happy_path_a_queued_video_gains_its_title_date_and_tags
    stub_request(:get, VIDEO_URL).to_return(status: 200, body: VIDEO_HTML)
    stub_request(:get, 'https://www.youtube.com/favicon.ico').to_return(status: 404, body: '')

    # 1. The user queues a link, so all the queue knows is the URL
    assert_equal :added, @queue_manager.add(VIDEO_URL, nil, nil)
    entry = @queue_manager.find_by_url(VIDEO_URL)

    assert_nil entry.title

    # 2. The worker fetches and stores what the page says about itself
    @worker.process(entry.id, VIDEO_URL)

    updated = @queue_manager.find_by_id(entry.id)

    assert_equal 'Rick Astley - Never Gonna Give You Up', updated.title
    assert_equal Time.parse(UPLOAD_DATE), updated.published_at

    # 3. It is tagged as a video, by its channel, and by the shipped rules
    tag_names = @queue_manager.tags_for_entry(entry.id).map(&:name)

    assert_includes tag_names, 'YouTube'
    assert_includes tag_names, 'Rick Astley'
  end

  def test_the_shipped_rules_tag_a_video_by_what_it_is_about
    url = 'https://www.youtube.com/watch?v=silksong1'
    html = VIDEO_HTML.sub('Rick Astley - Never Gonna Give You Up', 'Silksong playthrough, part 1')
    stub_request(:get, url).to_return(status: 200, body: html)
    stub_request(:get, 'https://www.youtube.com/favicon.ico').to_return(status: 404, body: '')

    @queue_manager.add(url, nil, nil)
    entry = @queue_manager.find_by_url(url)

    @worker.process(entry.id, url)

    tag_names = @queue_manager.tags_for_entry(entry.id).map(&:name)

    assert_includes tag_names, 'Silksong'
    assert_includes tag_names, 'Gaming'
  end

  def test_a_video_whose_page_omits_the_channel_is_tagged_from_the_oembed_api
    html = VIDEO_HTML.sub(/,\s*"author":.*?\}/m, '')
    stub_request(:get, VIDEO_URL).to_return(status: 200, body: html)
    stub_request(:get, 'https://www.youtube.com/favicon.ico').to_return(status: 404, body: '')
    stub_request(:get, 'https://www.youtube.com/oembed?format=json&url=' \
                       'https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ')
      .to_return(status: 200, body: { title: 'Never Gonna Give You Up', author_name: 'Rick Astley' }.to_json)

    @queue_manager.add(VIDEO_URL, nil, nil)
    entry = @queue_manager.find_by_url(VIDEO_URL)

    @worker.process(entry.id, VIDEO_URL)

    assert_includes @queue_manager.tags_for_entry(entry.id).map(&:name), 'Rick Astley'
  end

  def test_an_ordinary_page_gains_its_title_and_favicon
    url = 'https://example.com/article'
    stub_request(:get, url).to_return(
      status: 200,
      body: %(<html><head><title>An Article</title><link rel="icon" href="/icon.png"></head></html>)
    )
    stub_request(:get, 'https://example.com/icon.png').to_return(status: 200, body: 'PNGBYTES')

    @queue_manager.add(url, nil, nil)
    entry = @queue_manager.find_by_url(url)

    @worker.process(entry.id, url)

    updated = @queue_manager.find_by_id(entry.id)

    assert_equal 'An Article', updated.title
    assert_equal 'PNGBYTES', updated.favicon_data
    assert_empty @queue_manager.tags_for_entry(entry.id), 'no video tags for an ordinary page'
  end

  def test_an_enqueued_entry_is_processed_by_the_background_thread
    stub_request(:get, VIDEO_URL).to_return(status: 200, body: VIDEO_HTML)
    stub_request(:get, 'https://www.youtube.com/favicon.ico').to_return(status: 404, body: '')

    @queue_manager.add(VIDEO_URL, nil, nil)
    entry = @queue_manager.find_by_url(VIDEO_URL)

    @worker.enqueue(entry.id, VIDEO_URL)

    # Polling loop with a timeout: the work happens on the worker thread.
    tags = []
    50.times do
      tags = @queue_manager.tags_for_entry(entry.id)
      break if tags.length >= 2

      sleep 0.1
    end

    assert_includes tags.map(&:name), 'YouTube'
    assert_includes tags.map(&:name), 'Rick Astley'
  end
end
