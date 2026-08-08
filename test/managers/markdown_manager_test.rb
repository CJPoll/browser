require 'minitest/autorun'
require_relative '../../lib/managers/markdown_manager'

class ManagersMarkdownManagerTest < Minitest::Test
  URL = 'file:///tmp/notes.md'.freeze
  OTHER_URL = 'file:///tmp/other.md'.freeze
  CONTENT = "# The Heading\n\nbody text\n".freeze
  VIEW = :view_1
  OTHER_VIEW = :view_2

  # Stands in for Adapters::ContentFetcher.
  class MockContentFetcher
    attr_reader :fetched

    def initialize(content: CONTENT, error: nil)
      @content = content
      @error = error
      @fetched = []
    end

    def fetch(url)
      @fetched << url
      raise @error if @error

      @content.is_a?(Hash) ? @content[url] : @content
    end
  end

  def setup
    @fetcher = MockContentFetcher.new
    @manager = Managers::MarkdownManager.new(content_fetcher: @fetcher)
  end

  # === Recognising markdown ===

  def test_recognises_a_markdown_url
    assert @manager.markdown_url?(URL)
    refute @manager.markdown_url?('https://example.com/index.html')
  end

  # === Rendering ===

  def test_renders_the_fetched_document_for_the_url_it_came_from
    view = @manager.render(VIEW, URL)

    assert_equal URL, view.uri
    assert_includes view.html, '<title>The Heading</title>'
    assert_equal [URL], @fetcher.fetched
  end

  def test_does_not_fetch_a_url_that_is_not_markdown
    assert_nil @manager.render(VIEW, 'https://example.com/index.html')
    assert_empty @fetcher.fetched
  end

  def test_a_document_that_cannot_be_fetched_renders_as_nothing
    manager = Managers::MarkdownManager.new(content_fetcher: MockContentFetcher.new(content: nil))

    assert_nil manager.render(VIEW, URL)
    refute manager.showing_markdown?(VIEW)
  end

  # The fetch failing is the manager's problem to report, not the handler's:
  # the browser carries on and lets the webview load the URL itself.
  def test_a_fetch_that_fails_is_reported_and_renders_as_nothing
    manager = Managers::MarkdownManager.new(
      content_fetcher: MockContentFetcher.new(error: SocketError.new('no dns'))
    )

    view = nil
    _out, err = capture_io { view = manager.render(VIEW, URL) }

    assert_nil view
    assert_includes err, 'no dns'
    assert_includes err, URL
  end

  # === Remembering what a view is showing ===

  def test_a_view_is_not_showing_markdown_until_something_is_rendered_in_it
    refute @manager.showing_markdown?(VIEW)

    @manager.render(VIEW, URL)

    assert @manager.showing_markdown?(VIEW)
  end

  def test_keeps_the_source_of_what_it_rendered
    @manager.render(VIEW, URL)

    assert_equal CONTENT, @manager.source_content(VIEW)
  end

  def test_a_view_showing_nothing_has_no_source
    assert_nil @manager.source_content(VIEW)
  end

  def test_forgetting_a_view_forgets_what_it_was_showing
    @manager.render(VIEW, URL)

    @manager.forget(VIEW)

    refute @manager.showing_markdown?(VIEW)
    assert_nil @manager.source_content(VIEW)
  end

  def test_views_do_not_share_state
    fetcher = MockContentFetcher.new(content: { URL => CONTENT, OTHER_URL => "# Other\n" })
    manager = Managers::MarkdownManager.new(content_fetcher: fetcher)

    manager.render(VIEW, URL)
    manager.render(OTHER_VIEW, OTHER_URL)
    manager.forget(VIEW)

    refute manager.showing_markdown?(VIEW)
    assert manager.showing_markdown?(OTHER_VIEW)
    assert_equal "# Other\n", manager.source_content(OTHER_VIEW)
  end

  def test_rendering_again_in_the_same_view_replaces_what_it_was_showing
    fetcher = MockContentFetcher.new(content: { URL => CONTENT, OTHER_URL => "# Other\n" })
    manager = Managers::MarkdownManager.new(content_fetcher: fetcher)

    manager.render(VIEW, URL)
    view = manager.render(VIEW, OTHER_URL)

    assert_equal OTHER_URL, view.uri
    assert_equal "# Other\n", manager.source_content(VIEW)
  end

  # === Toggling to the source and back ===

  def test_toggling_shows_the_source_of_the_document
    @manager.render(VIEW, URL)

    view = @manager.toggle_source(VIEW)

    assert_equal URL, view.uri
    assert_includes view.html, '<title>The Heading (Source)</title>'
    assert_includes view.html, '# The Heading'
  end

  def test_toggling_twice_shows_the_rendered_document_again
    rendered = @manager.render(VIEW, URL)

    @manager.toggle_source(VIEW)
    view = @manager.toggle_source(VIEW)

    assert_equal rendered.html, view.html
  end

  def test_toggling_back_does_not_fetch_the_document_again
    @manager.render(VIEW, URL)

    @manager.toggle_source(VIEW)
    @manager.toggle_source(VIEW)

    assert_equal [URL], @fetcher.fetched
  end

  def test_a_view_showing_nothing_has_nothing_to_toggle
    assert_nil @manager.toggle_source(VIEW)
  end

  def test_rendering_a_new_document_starts_from_the_rendered_view_again
    fetcher = MockContentFetcher.new(content: { URL => CONTENT, OTHER_URL => "# Other\n" })
    manager = Managers::MarkdownManager.new(content_fetcher: fetcher)

    manager.render(VIEW, URL)
    manager.toggle_source(VIEW)
    manager.render(VIEW, OTHER_URL)
    view = manager.toggle_source(VIEW)

    assert_includes view.html, '<title>Other (Source)</title>'
  end
end
