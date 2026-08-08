require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/handlers/markdown_handler'

# The markdown stack end to end with nothing mocked: a real file on disk, the
# real fetcher, manager, renderer and handler. Only the webview is a stand-in
# -- WebKit cannot run in the test process.
class MarkdownFlowTest < Minitest::Test
  DOCUMENT = <<~MARKDOWN
    # Release Notes

    Some *text* and a [link](https://example.com).

    <!-- pagebreak -->

    ## Diagram

    ```mermaid
    graph TD;
      A-->B;
    ```
  MARKDOWN

  class FakeWebView
    attr_reader :loaded

    def initialize
      @loaded = []
    end

    def load_html(html, base_uri)
      @loaded << [html, base_uri]
    end

    def last_html
      @loaded.last&.first
    end
  end

  def setup
    @dir = Dir.mktmpdir('markdown-flow-test')
    @path = File.join(@dir, 'release notes.md')
    File.write(@path, DOCUMENT)
    @url = "file://#{@path.sub(' ', '%20')}"

    @scheduled = []
    @handler = MarkdownHandler.new(scheduler: ->(&block) { @scheduled << block })
    @webview = FakeWebView.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_renders_a_local_markdown_file_into_the_webview
    assert @handler.handle_navigation(@webview, @url)

    html = @webview.last_html

    assert_includes html, '<h1 id="release-notes">Release Notes</h1>'
    assert_includes html, '<em>text</em>'
    assert_includes html, 'href="https://example.com"'
    assert_equal @url, @webview.loaded.last.last, 'the rendered page stands for the original URL'
  end

  def test_the_rendered_page_carries_its_diagram_and_page_break
    @handler.handle_navigation(@webview, @url)

    html = @webview.last_html

    assert_includes html, '<pre class="mermaid">'
    assert_includes html, 'A-->B;'
    assert_includes html, 'mermaid.min.js'
    assert_includes html, '<div class="page-break"></div>'
    assert_includes html, 'page-break-after: always'
  end

  def test_toggles_to_the_source_and_back
    @handler.handle_navigation(@webview, @url)
    rendered = @webview.last_html

    assert @handler.toggle_view(@webview)
    source = @webview.last_html

    assert_includes source, '# Release Notes'
    assert_includes source, '&lt;!-- pagebreak --&gt;'
    refute_includes source, '<h1 id="release-notes">'

    assert @handler.toggle_view(@webview)
    assert_equal rendered, @webview.last_html
  end

  def test_hands_the_markdown_source_to_the_pdf_bookmark_pipeline
    @handler.handle_navigation(@webview, @url)

    assert @handler.showing_markdown?(@webview)
    assert_equal DOCUMENT, @handler.get_markdown_content(@webview)

    @handler.clear_state(@webview)

    refute @handler.showing_markdown?(@webview)
  end

  def test_leaves_a_file_that_is_not_there_to_the_webview
    refute @handler.handle_navigation(@webview, "file://#{@dir}/absent.md")

    assert_empty @webview.loaded
  end

  def test_leaves_a_page_that_is_not_markdown_to_the_webview
    refute @handler.handle_navigation(@webview, 'https://example.com/index.html')

    assert_empty @webview.loaded
  end
end
