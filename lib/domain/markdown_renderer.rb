# frozen_string_literal: true

require 'redcarpet'
require 'cgi'
require_relative 'markdown_document'
require_relative 'markdown_styles'
require_relative 'mermaid_script'

module Domain
  # Turns a markdown document into the HTML page the browser displays.
  #
  # Redcarpet is a text-to-text transform with no IO of its own, so the whole
  # pipeline is a pure function of the content and the URL it came from --
  # which is what makes the dialect (tables, footnotes, autolinks) and the
  # mermaid and page-break handling testable without a webview.
  module MarkdownRenderer
    RENDER_OPTIONS = {
      hard_wrap: true,
      link_attributes: { target: '_blank' },
      with_toc_data: true # Heading ids, so a table of contents can link to them
    }.freeze

    MARKDOWN_EXTENSIONS = {
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      underline: true,
      highlight: true,
      quote: true,
      footnotes: true,
      no_intra_emphasis: true
    }.freeze

    # Renders a markdown document as a complete, self-contained HTML page.
    #
    # @param content [String] Raw markdown content
    # @param url [String] URL the content came from, used for the title
    # @return [String] HTML document
    def self.render(content, url)
      title = MarkdownDocument.title(content, url)
      source = MarkdownDocument.apply_page_breaks(content)
      body_html = markdown_engine.render(source)

      mermaid = MarkdownDocument.mermaid?(source)
      body_html = MarkdownDocument.promote_mermaid_blocks(body_html) if mermaid

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>#{CGI.escapeHTML(title)}</title>
          <style>
            #{MarkdownStyles.rendered_css}
          </style>
          #{MermaidScript.library_tag if mermaid}
        </head>
        <body>
          <div class="markdown-body">
            #{body_html}
          </div>
          <div class="view-toggle">
            <span class="hint">Press Ctrl+U to view source</span>
          </div>
          #{MermaidScript.init_script if mermaid}
        </body>
        </html>
      HTML
    end

    # Renders the markdown source itself as a complete HTML page (Ctrl+U).
    #
    # @param content [String] Raw markdown content
    # @param url [String] URL the content came from, used for the title
    # @return [String] HTML document
    def self.render_source(content, url)
      title = MarkdownDocument.title(content, url)

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>#{CGI.escapeHTML(title)} (Source)</title>
          <style>
            #{MarkdownStyles.raw_css}
          </style>
        </head>
        <body>
          <div class="raw-body">
            <pre><code>#{CGI.escapeHTML(content)}</code></pre>
          </div>
          <div class="view-toggle">
            <span class="hint">Press Ctrl+U to view rendered</span>
          </div>
        </body>
        </html>
      HTML
    end

    # A fresh engine per render: Redcarpet's renderer objects carry state
    # between calls, so a shared one would make a document's HTML depend on
    # what was rendered before it.
    #
    # @return [Redcarpet::Markdown]
    def self.markdown_engine
      Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(**RENDER_OPTIONS), **MARKDOWN_EXTENSIONS)
    end
    private_class_method :markdown_engine
  end
end
