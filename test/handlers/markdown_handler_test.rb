require 'minitest/autorun'
require_relative '../../lib/domain/markdown_view'
require_relative '../../lib/handlers/markdown_handler'

class HandlersMarkdownHandlerTest < Minitest::Test
  URL = 'file:///tmp/notes.md'.freeze
  HTML = '<html>rendered</html>'.freeze
  SOURCE_HTML = '<html>source</html>'.freeze

  # The handler only ever asks a webview to load HTML, so a fake needs one
  # method and a record of what it was given.
  class FakeWebView
    attr_reader :loaded

    def initialize
      @loaded = []
    end

    def load_html(html, base_uri)
      @loaded << [html, base_uri]
    end
  end

  # Stands in for Managers::MarkdownManager.
  class SpyMarkdownManager
    attr_reader :rendered, :toggled, :forgotten

    def initialize(view: Domain::MarkdownView.new(uri: URL, html: HTML), source_view: nil)
      @view = view
      @source_view = source_view
      @rendered = []
      @toggled = []
      @forgotten = []
      @showing = {}
    end

    def markdown_url?(url)
      url.to_s.end_with?('.md')
    end

    def render(view_key, url)
      @rendered << [view_key, url]
      return nil unless @view

      @showing[view_key] = true
      @view
    end

    def toggle_source(view_key)
      @toggled << view_key
      @source_view
    end

    def showing_markdown?(view_key)
      @showing.fetch(view_key, false)
    end

    def source_content(view_key)
      @showing[view_key] ? "# Source of #{view_key}" : nil
    end

    def forget(view_key)
      @forgotten << view_key
      @showing.delete(view_key)
    end
  end

  def setup
    @scheduled = []
    @manager = SpyMarkdownManager.new
    @handler = MarkdownHandler.new(manager: @manager, scheduler: ->(&block) { @scheduled << block })
    @webview = FakeWebView.new
  end

  # === Navigation ===

  def test_loads_the_rendered_document_into_the_webview
    assert @handler.handle_navigation(@webview, URL)
    assert_equal [[HTML, URL]], @webview.loaded
  end

  def test_leaves_a_url_that_is_not_markdown_to_the_webview
    refute @handler.handle_navigation(@webview, 'https://example.com/index.html')

    assert_empty @webview.loaded
    assert_empty @manager.rendered
  end

  def test_leaves_a_document_that_could_not_be_rendered_to_the_webview
    handler = MarkdownHandler.new(manager: SpyMarkdownManager.new(view: nil),
                                  scheduler: ->(&block) { @scheduled << block })

    refute handler.handle_navigation(@webview, URL)
    assert_empty @webview.loaded
  end

  # Loading the rendered HTML makes WebKit ask about the same URL again; a
  # second render would refetch the document and recurse.
  def test_does_not_render_the_document_the_load_it_just_started_asks_about
    @handler.handle_navigation(@webview, URL)

    refute @handler.handle_navigation(@webview, URL)

    assert_equal 1, @manager.rendered.length
    assert_equal 1, @webview.loaded.length
  end

  def test_renders_the_document_again_once_the_load_it_started_has_gone_through
    @handler.handle_navigation(@webview, URL)
    run_scheduled_work

    assert @handler.handle_navigation(@webview, URL)
    assert_equal 2, @manager.rendered.length
  end

  def test_clears_the_recursion_guard_on_the_main_thread_rather_than_the_caller
    @handler.handle_navigation(@webview, URL)

    assert_equal 1, @scheduled.length, 'expected the guard to be cleared through the scheduler'
    refute @handler.handle_navigation(@webview, URL), 'guard was cleared before the scheduled work ran'
  end

  def test_a_second_webview_showing_the_same_document_keeps_its_own_state
    other_webview = FakeWebView.new

    @handler.handle_navigation(@webview, URL)
    run_scheduled_work
    @handler.handle_navigation(other_webview, URL)

    assert_equal [[@webview.object_id, URL], [other_webview.object_id, URL]], @manager.rendered
  end

  # === Toggling the source view ===

  def test_loads_the_source_view_when_toggled
    manager = SpyMarkdownManager.new(source_view: Domain::MarkdownView.new(uri: URL, html: SOURCE_HTML))
    handler = MarkdownHandler.new(manager: manager, scheduler: ->(&block) { @scheduled << block })

    assert handler.toggle_view(@webview)
    assert_equal [[SOURCE_HTML, URL]], @webview.loaded
    assert_equal [@webview.object_id], manager.toggled
  end

  def test_toggling_a_webview_showing_no_markdown_does_nothing
    refute @handler.toggle_view(@webview)
    assert_empty @webview.loaded
  end

  def test_does_not_render_the_document_the_toggle_asks_about_again
    manager = SpyMarkdownManager.new(source_view: Domain::MarkdownView.new(uri: URL, html: SOURCE_HTML))
    handler = MarkdownHandler.new(manager: manager, scheduler: ->(&block) { @scheduled << block })

    handler.toggle_view(@webview)

    refute handler.handle_navigation(@webview, URL)
    assert_empty manager.rendered
  end

  # === What the window asks about a webview ===

  def test_reports_whether_a_webview_is_showing_markdown
    refute @handler.showing_markdown?(@webview)

    @handler.handle_navigation(@webview, URL)

    assert @handler.showing_markdown?(@webview)
  end

  def test_hands_back_the_markdown_source_for_a_webview
    @handler.handle_navigation(@webview, URL)

    assert_equal "# Source of #{@webview.object_id}", @handler.get_markdown_content(@webview)
  end

  def test_clearing_a_webview_forgets_what_it_was_showing
    @handler.handle_navigation(@webview, URL)

    @handler.clear_state(@webview)

    assert_equal [@webview.object_id], @manager.forgotten
    refute @handler.showing_markdown?(@webview)
  end

  private

  def run_scheduled_work
    scheduled = @scheduled.dup
    @scheduled.clear
    scheduled.each(&:call)
  end
end
