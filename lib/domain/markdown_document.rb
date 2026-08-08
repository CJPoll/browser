# frozen_string_literal: true

require 'uri'
require 'cgi'

module Domain
  # What a markdown document says about itself, and the text transforms the
  # browser applies before handing it to a markdown renderer.
  #
  # Every method here is a pure function of its arguments: nothing is read from
  # disk or the network, and `File.basename` is used only as a path-string
  # helper.
  module MarkdownDocument
    MARKDOWN_EXTENSIONS = ['.md', '.markdown'].freeze

    # `<!-- pagebreak -->` and its hyphenated, underscored and shouted variants
    PAGE_BREAK_MARKER = /<!--\s*page[\s\-_]?break\s*-->/i
    PAGE_BREAK_ELEMENT = '<div class="page-break"></div>'

    # Redcarpet renders ```mermaid as <pre><code class="mermaid">...
    # Mermaid.js expects <pre class="mermaid">...
    MERMAID_FENCE = '```mermaid'
    MERMAID_CODE_BLOCK = %r{<pre><code class="mermaid">(.*?)</code></pre>}m

    UNTITLED = 'Markdown'
    FIRST_HEADING = /^#\s+(.+?)$/

    # Does this URL name a markdown file?
    #
    # @param url [String, nil] URL to check
    # @return [Boolean] true when the path ends in a markdown extension
    def self.markdown_url?(url)
      return false unless url

      path = URI.parse(url).path.to_s.downcase
      MARKDOWN_EXTENSIONS.any? { |extension| path.end_with?(extension) }
    rescue URI::InvalidURIError
      false
    end

    # The document's title: its first top-level heading, or failing that the
    # file name the URL points at.
    #
    # @param content [String] Raw markdown content
    # @param url [String] URL the content came from
    # @return [String] Title
    def self.title(content, url)
      heading = content[FIRST_HEADING, 1]
      return heading.strip if heading

      File.basename(CGI.unescape(URI.parse(url).path.to_s), '.*')
    rescue StandardError
      UNTITLED
    end

    # Replaces page-break comments with the element the print stylesheet knows
    # how to break on.
    #
    # @param content [String] Raw markdown content
    # @return [String] Markdown with page-break elements
    def self.apply_page_breaks(content)
      content.gsub(PAGE_BREAK_MARKER, PAGE_BREAK_ELEMENT)
    end

    # Does this document contain a mermaid diagram?
    #
    # @param content [String] Raw markdown content
    # @return [Boolean]
    def self.mermaid?(content)
      content.include?(MERMAID_FENCE)
    end

    # Rewrites rendered mermaid code blocks into the elements Mermaid.js looks
    # for, undoing the HTML escaping the markdown renderer applied to the
    # diagram source.
    #
    # @param html [String] Rendered HTML
    # @return [String] HTML with mermaid elements
    def self.promote_mermaid_blocks(html)
      html.gsub(MERMAID_CODE_BLOCK) do
        %(<pre class="mermaid">#{CGI.unescapeHTML(Regexp.last_match(1))}</pre>)
      end
    end
  end
end
