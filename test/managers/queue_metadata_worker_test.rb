require 'minitest/autorun'
require 'stringio'
require_relative '../../lib/managers/queue_metadata_worker'

# Records what the worker asked the queue to store.
class MockQueueManager
  attr_reader :titles, :favicons, :published_at, :assigned_tags

  def initialize(known_entry_ids: [1])
    @known_entry_ids = known_entry_ids
    @titles = {}
    @favicons = {}
    @published_at = {}
    @assigned_tags = []
  end

  def update_title(url, title) = @titles[url] = title
  def update_favicon(url, data) = @favicons[url] = data
  def update_published_at(url, time) = @published_at[url] = time
  def find_by_id(id) = @known_entry_ids.include?(id) ? Object.new : nil
  def assign_tag_by_name(entry_id, tag_name) = @assigned_tags << [entry_id, tag_name]
end

# Answers with canned bodies, or raises what it was told to raise.
class MockHttpFetcher
  attr_reader :requested

  def initialize(pages: {}, apis: {}, assets: {})
    @pages = pages
    @apis = apis
    @assets = assets
    @requested = []
  end

  def fetch_page(url) = answer(@pages, url)
  def fetch_api(url) = answer(@apis, url)
  def fetch_asset(url) = answer(@assets, url)

  private

  def answer(source, url)
    @requested << url
    body = source[url]
    raise body if body.is_a?(Exception)

    body
  end
end

class ManagersQueueMetadataWorkerTest < Minitest::Test
  ENTRY_ID = 1
  PAGE_URL = 'https://example.com/article'
  VIDEO_URL = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
  OEMBED_URL = Domain::PageMetadata.oembed_url(VIDEO_URL)
  UPLOAD_DATE = '2009-10-25T07:00:00Z'

  def teardown
    @worker&.stop
  end

  def build_worker(http:, queue_manager: MockQueueManager.new, auto_tagger: Domain::AutoTagger.new,
                   scheduler: ->(&block) { block.call })
    @queue_manager = queue_manager
    @worker = Managers::QueueMetadataWorker.new(queue_manager, http: http, auto_tagger: auto_tagger,
                                                               scheduler: scheduler)
  end

  def page_html(title: 'An Article', favicon: nil)
    icon = favicon ? %(<link rel="icon" href="#{favicon}">) : ''
    "<html><head><title>#{title}</title>#{icon}</head></html>"
  end

  def video_html(title: 'Never Gonna Give You Up', channel: nil, date: UPLOAD_DATE)
    author = channel ? %(, "author": { "name": "#{channel}" }) : ''
    <<~HTML
      <html><head><script type="application/ld+json">
      {"@type": "VideoObject", "name": "#{title}", "uploadDate": "#{date}"#{author}}
      </script></head></html>
    HTML
  end

  def silence_warnings
    original = $stderr
    $stderr = StringIO.new
    yield $stderr
  ensure
    $stderr = original
  end

  # --- an ordinary page ----------------------------------------------------

  def test_stores_the_page_title
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => page_html }))

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_equal({ PAGE_URL => 'An Article' }, @queue_manager.titles)
  end

  def test_stores_the_favicon_the_page_points_at
    http = MockHttpFetcher.new(
      pages: { PAGE_URL => page_html(favicon: '/icon.png') },
      assets: { 'https://example.com/icon.png' => 'PNGBYTES' }
    )
    build_worker(http: http)

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_equal({ PAGE_URL => 'PNGBYTES' }, @queue_manager.favicons)
  end

  def test_falls_back_to_the_conventional_favicon_path
    http = MockHttpFetcher.new(pages: { PAGE_URL => page_html },
                               assets: { 'https://example.com/favicon.ico' => 'ICOBYTES' })
    build_worker(http: http)

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_equal({ PAGE_URL => 'ICOBYTES' }, @queue_manager.favicons)
  end

  def test_stores_nothing_when_the_page_cannot_be_fetched
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => nil }))

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_empty @queue_manager.titles
    assert_empty @queue_manager.favicons
    assert_empty @queue_manager.assigned_tags
  end

  def test_a_page_without_a_title_stores_nothing_for_it
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => '<html><body>x</body></html>' }))

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_empty @queue_manager.titles
  end

  def test_a_favicon_that_cannot_be_fetched_is_not_worth_reporting
    http = MockHttpFetcher.new(pages: { PAGE_URL => page_html },
                               assets: { 'https://example.com/favicon.ico' => SocketError.new('down') })
    build_worker(http: http)

    @worker.process(ENTRY_ID, PAGE_URL) # does not raise

    assert_empty @queue_manager.favicons
    assert_equal({ PAGE_URL => 'An Article' }, @queue_manager.titles)
  end

  def test_an_ordinary_page_is_not_tagged_as_a_video
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => page_html }))

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_empty @queue_manager.assigned_tags
  end

  # --- a YouTube video -----------------------------------------------------

  def test_reads_the_video_title_and_date_from_the_page
    build_worker(http: MockHttpFetcher.new(pages: { VIDEO_URL => video_html(channel: 'Rick Astley') }))

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_equal({ VIDEO_URL => 'Never Gonna Give You Up' }, @queue_manager.titles)
    assert_equal({ VIDEO_URL => Time.parse(UPLOAD_DATE) }, @queue_manager.published_at)
  end

  def test_tags_a_video_with_youtube_and_its_channel
    build_worker(http: MockHttpFetcher.new(pages: { VIDEO_URL => video_html(channel: 'Rick Astley') }))

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_equal [[ENTRY_ID, 'YouTube'], [ENTRY_ID, 'Rick Astley']], @queue_manager.assigned_tags
  end

  def test_asks_the_oembed_api_for_the_channel_the_page_does_not_name
    http = MockHttpFetcher.new(
      pages: { VIDEO_URL => video_html },
      apis: { OEMBED_URL => '{"title": "oEmbed Title", "author_name": "Rick Astley"}' }
    )
    build_worker(http: http)

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_includes @queue_manager.assigned_tags, [ENTRY_ID, 'Rick Astley']
    assert_equal 'Never Gonna Give You Up', @queue_manager.titles[VIDEO_URL],
                 "the page's own title wins over oEmbed's"
  end

  def test_does_not_ask_the_oembed_api_when_the_page_names_the_channel
    http = MockHttpFetcher.new(pages: { VIDEO_URL => video_html(channel: 'Rick Astley') })
    build_worker(http: http)

    @worker.process(ENTRY_ID, VIDEO_URL)

    refute_includes http.requested, OEMBED_URL
  end

  def test_falls_back_to_the_oembed_title_when_the_page_has_no_structured_data
    http = MockHttpFetcher.new(
      pages: { VIDEO_URL => page_html(title: 'YouTube') },
      apis: { OEMBED_URL => '{"title": "oEmbed Title", "author_name": "Rick Astley"}' }
    )
    build_worker(http: http)

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_equal({ VIDEO_URL => 'oEmbed Title' }, @queue_manager.titles)
  end

  def test_a_video_is_still_stored_when_the_oembed_api_fails
    http = MockHttpFetcher.new(pages: { VIDEO_URL => video_html },
                               apis: { OEMBED_URL => SocketError.new('down') })
    build_worker(http: http)

    warnings = silence_warnings { |io| @worker.process(ENTRY_ID, VIDEO_URL); io }.string

    assert_equal({ VIDEO_URL => 'Never Gonna Give You Up' }, @queue_manager.titles)
    assert_equal [[ENTRY_ID, 'YouTube']], @queue_manager.assigned_tags
    assert_match(/oEmbed API error/, warnings)
  end

  def test_a_blank_channel_is_not_tagged
    http = MockHttpFetcher.new(pages: { VIDEO_URL => video_html },
                               apis: { OEMBED_URL => '{"title": "T", "author_name": "   "}' })
    build_worker(http: http)

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_equal [[ENTRY_ID, 'YouTube']], @queue_manager.assigned_tags
  end

  # WART (preserved): an entry removed from the queue between being enqueued
  # and being fetched stops tagging entirely -- the rule-based tags below the
  # YouTube block are skipped along with the channel tag.
  def test_wart_a_removed_entry_gets_no_tags_at_all
    tagger = Domain::AutoTagger.new
    tagger.add(tag_name: 'Music', patterns: ['gonna'], fields: :title)
    build_worker(http: MockHttpFetcher.new(pages: { VIDEO_URL => video_html(channel: 'Rick Astley') }),
                 queue_manager: MockQueueManager.new(known_entry_ids: []),
                 auto_tagger: tagger)

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_empty @queue_manager.assigned_tags
    assert_equal({ VIDEO_URL => 'Never Gonna Give You Up' }, @queue_manager.titles,
                 'the title is still stored')
  end

  # --- rule-based tagging --------------------------------------------------

  def test_applies_the_tagging_rules_to_what_it_read
    tagger = Domain::AutoTagger.new
    tagger.add(tag_name: 'Music', patterns: ['gonna'], fields: :title)
    tagger.add(tag_name: 'Rick', patterns: ['astley'], fields: :channel)
    build_worker(http: MockHttpFetcher.new(pages: { VIDEO_URL => video_html(channel: 'Rick Astley') }),
                 auto_tagger: tagger)

    @worker.process(ENTRY_ID, VIDEO_URL)

    assert_equal [[ENTRY_ID, 'YouTube'], [ENTRY_ID, 'Rick Astley'],
                  [ENTRY_ID, 'Music'], [ENTRY_ID, 'Rick']], @queue_manager.assigned_tags
  end

  def test_the_rules_apply_to_ordinary_pages_too
    tagger = Domain::AutoTagger.new
    tagger.add(tag_name: 'Reading', patterns: ['article'], fields: :title)
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => page_html }), auto_tagger: tagger)

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_equal [[ENTRY_ID, 'Reading']], @queue_manager.assigned_tags
  end

  # --- lifecycle -----------------------------------------------------------

  def test_announces_a_fetch_on_the_main_thread
    announced = 0
    scheduled = []
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => page_html }),
                 scheduler: ->(&block) { scheduled << block })
    @worker.on_metadata_fetched = -> { announced += 1 }

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_equal 1, scheduled.length, 'the callback is handed to the main thread, not called on this one'
    scheduled.first.call

    assert_equal 1, announced
  end

  def test_announces_nothing_when_the_page_could_not_be_fetched
    scheduled = []
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => nil }),
                 scheduler: ->(&block) { scheduled << block })
    @worker.on_metadata_fetched = -> { flunk 'should not be announced' }

    @worker.process(ENTRY_ID, PAGE_URL)

    assert_empty scheduled
  end

  def test_an_enqueued_entry_is_processed_on_the_worker_thread
    build_worker(http: MockHttpFetcher.new(pages: { PAGE_URL => page_html }))

    @worker.enqueue(ENTRY_ID, PAGE_URL)

    50.times do
      break unless @queue_manager.titles.empty?

      sleep 0.02 # Polling loop: the work happens on another thread
    end

    assert_equal({ PAGE_URL => 'An Article' }, @queue_manager.titles)
  end

  def test_a_failure_on_the_worker_thread_does_not_stop_the_worker
    http = MockHttpFetcher.new(pages: { 'https://broken.example' => SocketError.new('down'),
                                        PAGE_URL => page_html })
    build_worker(http: http)

    silence_warnings do
      @worker.enqueue(ENTRY_ID, 'https://broken.example')
      @worker.enqueue(ENTRY_ID, PAGE_URL)

      50.times do
        break unless @queue_manager.titles.empty?

        sleep 0.02 # Polling loop: the work happens on another thread
      end
    end

    assert_equal({ PAGE_URL => 'An Article' }, @queue_manager.titles)
  end

  def test_stop_ends_the_worker_thread
    build_worker(http: MockHttpFetcher.new)

    @worker.stop

    refute @worker.instance_variable_get(:@worker_thread).alive?
  end
end
