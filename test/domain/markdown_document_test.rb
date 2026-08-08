require 'minitest/autorun'
require_relative '../../lib/domain/markdown_document'

class DomainMarkdownDocumentTest < Minitest::Test
  # === markdown_url? ===

  def test_recognises_a_dot_md_url
    assert Domain::MarkdownDocument.markdown_url?('https://example.com/README.md')
  end

  def test_recognises_a_dot_markdown_url
    assert Domain::MarkdownDocument.markdown_url?('https://example.com/notes.markdown')
  end

  def test_recognises_the_extension_whatever_its_case
    assert Domain::MarkdownDocument.markdown_url?('https://example.com/README.MD')
    assert Domain::MarkdownDocument.markdown_url?('file:///tmp/Notes.MarkDown')
  end

  def test_recognises_a_local_file
    assert Domain::MarkdownDocument.markdown_url?('file:///home/user/notes.md')
  end

  def test_ignores_the_query_string
    assert Domain::MarkdownDocument.markdown_url?('https://example.com/a.md?raw=1')
    refute Domain::MarkdownDocument.markdown_url?('https://example.com/a.html?file=b.md')
  end

  def test_a_page_that_is_not_markdown_is_not_markdown
    refute Domain::MarkdownDocument.markdown_url?('https://example.com/index.html')
  end

  def test_a_url_that_merely_mentions_md_is_not_markdown
    refute Domain::MarkdownDocument.markdown_url?('https://example.com/md/page')
    refute Domain::MarkdownDocument.markdown_url?('https://example.com/readme.mdx')
  end

  def test_nothing_is_not_markdown
    refute Domain::MarkdownDocument.markdown_url?(nil)
    refute Domain::MarkdownDocument.markdown_url?('')
  end

  def test_an_unparseable_url_is_not_markdown
    refute Domain::MarkdownDocument.markdown_url?('http://exa mple.com/a.md')
  end

  # === title ===

  def test_takes_the_title_from_the_first_heading
    content = "# The Heading\n\nbody text\n"

    assert_equal 'The Heading', Domain::MarkdownDocument.title(content, 'file:///tmp/notes.md')
  end

  def test_trims_the_heading
    content = "#   Spaced   \n"

    assert_equal 'Spaced', Domain::MarkdownDocument.title(content, 'file:///tmp/notes.md')
  end

  def test_ignores_a_deeper_heading_when_looking_for_a_title
    content = "## Second Level\n\n# Top Level\n"

    assert_equal 'Top Level', Domain::MarkdownDocument.title(content, 'file:///tmp/notes.md')
  end

  def test_falls_back_to_the_file_name_without_its_extension
    content = "no headings here\n"

    assert_equal 'notes', Domain::MarkdownDocument.title(content, 'file:///tmp/notes.md')
  end

  def test_unescapes_the_file_name
    content = 'no headings'

    assert_equal 'my notes', Domain::MarkdownDocument.title(content, 'file:///tmp/my%20notes.md')
  end

  def test_falls_back_to_the_last_path_segment_of_a_remote_url
    content = 'no headings'

    assert_equal 'README', Domain::MarkdownDocument.title(content, 'https://example.com/docs/README.md')
  end

  def test_a_url_that_cannot_be_parsed_titles_as_markdown
    content = 'no headings'

    assert_equal 'Markdown', Domain::MarkdownDocument.title(content, 'http://exa mple.com/a.md')
  end

  # Known wart, preserved from the original handler: the heading regexp is not
  # aware of fenced code blocks, so a commented shell line can become the title.
  def test_wart_a_heading_inside_a_code_block_still_wins
    content = "```sh\n# not really a heading\n```\n"

    assert_equal 'not really a heading', Domain::MarkdownDocument.title(content, 'file:///tmp/notes.md')
  end

  # === page breaks ===

  def test_turns_a_pagebreak_comment_into_a_page_break_element
    assert_equal '<div class="page-break"></div>',
                 Domain::MarkdownDocument.apply_page_breaks('<!-- pagebreak -->')
  end

  def test_accepts_the_hyphenated_underscored_and_shouted_spellings
    ['<!-- page-break -->', '<!-- page_break -->', '<!-- PAGEBREAK -->', '<!--pagebreak-->'].each do |marker|
      assert_equal '<div class="page-break"></div>',
                   Domain::MarkdownDocument.apply_page_breaks(marker),
                   "expected #{marker} to be a page break"
    end
  end

  def test_replaces_every_page_break_and_leaves_the_rest_alone
    content = "one\n\n<!-- pagebreak -->\n\ntwo\n\n<!-- page-break -->\n\nthree"

    result = Domain::MarkdownDocument.apply_page_breaks(content)

    assert_equal 2, result.scan('<div class="page-break"></div>').length
    assert_includes result, "one\n"
    assert_includes result, "three"
  end

  def test_leaves_an_unrelated_comment_alone
    content = '<!-- just a note -->'

    assert_equal content, Domain::MarkdownDocument.apply_page_breaks(content)
  end

  # === mermaid ===

  def test_notices_a_mermaid_fence
    assert Domain::MarkdownDocument.mermaid?("text\n\n```mermaid\ngraph TD;\n```\n")
  end

  def test_a_document_without_a_mermaid_fence_has_no_diagrams
    refute Domain::MarkdownDocument.mermaid?("```ruby\nputs 1\n```")
    refute Domain::MarkdownDocument.mermaid?('')
  end

  def test_promotes_a_mermaid_code_block_to_a_mermaid_element
    html = %(<pre><code class="mermaid">graph TD;\n  A--&gt;B;\n</code></pre>)

    assert_equal %(<pre class="mermaid">graph TD;\n  A-->B;\n</pre>),
                 Domain::MarkdownDocument.promote_mermaid_blocks(html)
  end

  def test_promotes_every_mermaid_block
    html = %(<pre><code class="mermaid">a</code></pre><p>x</p><pre><code class="mermaid">b</code></pre>)

    result = Domain::MarkdownDocument.promote_mermaid_blocks(html)

    assert_equal %(<pre class="mermaid">a</pre><p>x</p><pre class="mermaid">b</pre>), result
  end

  def test_leaves_other_code_blocks_alone
    html = %(<pre><code class="ruby">puts 1</code></pre>)

    assert_equal html, Domain::MarkdownDocument.promote_mermaid_blocks(html)
  end
end
