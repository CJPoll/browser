require 'minitest/autorun'
require_relative '../../lib/domain/markdown_renderer'

class DomainMarkdownRendererTest < Minitest::Test
  URL = 'file:///tmp/notes.md'.freeze

  # === The rendered document ===

  def test_renders_the_markdown_body
    html = Domain::MarkdownRenderer.render("# Title\n\nsome *emphasis*\n", URL)

    assert_includes html, '<h1'
    assert_includes html, '<em>emphasis</em>'
  end

  def test_the_document_stands_on_its_own
    html = Domain::MarkdownRenderer.render("# Title\n", URL)

    assert html.start_with?('<!DOCTYPE html>'), 'expected a complete HTML document'
    assert_includes html, '<meta charset="utf-8">'
    assert_includes html, '</html>'
  end

  def test_titles_the_document_from_its_first_heading
    html = Domain::MarkdownRenderer.render("# The Heading\n", URL)

    assert_includes html, '<title>The Heading</title>'
  end

  def test_escapes_the_title
    html = Domain::MarkdownRenderer.render("# A <script> & co\n", URL)

    assert_includes html, '<title>A &lt;script&gt; &amp; co</title>'
    refute_includes html, '<title>A <script>'
  end

  def test_carries_the_stylesheet
    html = Domain::MarkdownRenderer.render('body', URL)

    assert_includes html, Domain::MarkdownStyles.rendered_css
  end

  def test_tells_the_reader_how_to_see_the_source
    html = Domain::MarkdownRenderer.render('body', URL)

    assert_includes html, 'Press Ctrl+U to view source'
  end

  # === Markdown dialect ===

  def test_renders_tables
    html = Domain::MarkdownRenderer.render("| a | b |\n| - | - |\n| 1 | 2 |\n", URL)

    assert_includes html, '<table>'
  end

  def test_renders_fenced_code_blocks
    html = Domain::MarkdownRenderer.render("```ruby\nputs 1\n```\n", URL)

    assert_includes html, '<code class="ruby">'
  end

  def test_renders_strikethrough
    html = Domain::MarkdownRenderer.render("~~gone~~\n", URL)

    assert_includes html, '<del>gone</del>'
  end

  def test_autolinks_bare_urls
    html = Domain::MarkdownRenderer.render("see https://example.com now\n", URL)

    assert_includes html, 'href="https://example.com"'
  end

  def test_opens_links_in_a_new_tab
    html = Domain::MarkdownRenderer.render("[link](https://example.com)\n", URL)

    assert_includes html, 'target="_blank"'
  end

  def test_gives_headings_anchors_so_the_table_of_contents_can_link_to_them
    html = Domain::MarkdownRenderer.render("## A Section\n", URL)

    assert_includes html, 'id="a-section"'
  end

  # === Page breaks ===

  def test_turns_a_pagebreak_comment_into_a_page_break_element
    html = Domain::MarkdownRenderer.render("one\n\n<!-- pagebreak -->\n\ntwo\n", URL)

    assert_includes html, '<div class="page-break"></div>'
  end

  # === Mermaid ===

  def test_loads_mermaid_only_when_the_document_has_a_diagram
    with_diagram = Domain::MarkdownRenderer.render("```mermaid\ngraph TD;\n  A-->B;\n```\n", URL)
    without_diagram = Domain::MarkdownRenderer.render("```ruby\nputs 1\n```\n", URL)

    assert_includes with_diagram, Domain::MermaidScript.library_tag.strip
    assert_includes with_diagram, 'mermaid.initialize'
    refute_includes without_diagram, 'mermaid.min.js'
    refute_includes without_diagram, 'mermaid.initialize'
  end

  def test_hands_the_diagram_source_to_mermaid_unescaped
    html = Domain::MarkdownRenderer.render("```mermaid\ngraph TD;\n  A-->B;\n```\n", URL)

    assert_includes html, '<pre class="mermaid">'
    assert_includes html, 'A-->B;'
    refute_includes html, '<code class="mermaid">'
  end

  # === The source view ===

  def test_the_source_view_shows_the_markdown_verbatim
    html = Domain::MarkdownRenderer.render_source("# Title\n\n- a list item\n", URL)

    assert_includes html, "# Title\n\n- a list item\n"
    refute_includes html, '<h1'
  end

  def test_the_source_view_escapes_the_content
    html = Domain::MarkdownRenderer.render_source("<script>alert(1)</script>\n", URL)

    assert_includes html, '&lt;script&gt;alert(1)&lt;/script&gt;'
    refute_includes html, '<script>alert(1)'
  end

  def test_the_source_view_says_it_is_the_source
    html = Domain::MarkdownRenderer.render_source("# The Heading\n", URL)

    assert_includes html, '<title>The Heading (Source)</title>'
    assert_includes html, 'Press Ctrl+U to view rendered'
  end

  def test_the_source_view_carries_its_own_stylesheet
    html = Domain::MarkdownRenderer.render_source('body', URL)

    assert_includes html, Domain::MarkdownStyles.raw_css
    assert html.start_with?('<!DOCTYPE html>'), 'expected a complete HTML document'
  end

  # === Purity ===

  def test_rendering_the_same_document_twice_gives_the_same_html
    content = "# Title\n\n```mermaid\ngraph TD;\n```\n"

    assert_equal Domain::MarkdownRenderer.render(content, URL),
                 Domain::MarkdownRenderer.render(content, URL)
  end

  def test_rendering_does_not_alter_the_content_it_was_given
    content = +"one\n\n<!-- pagebreak -->\n\ntwo\n"

    Domain::MarkdownRenderer.render(content, URL)

    assert_equal "one\n\n<!-- pagebreak -->\n\ntwo\n", content
  end
end
