# frozen_string_literal: true

require_relative '../adapters/content_fetcher'
require_relative '../domain/markdown_document'
require_relative '../domain/markdown_renderer'
require_relative '../domain/markdown_view'

module Managers
  # Renders markdown documents the browser displays itself, and remembers
  # which of the two views -- rendered or source -- each webview is showing.
  #
  # Views are named by an opaque key supplied by the Framework, so no WebKit
  # object reaches this bucket.
  class MarkdownManager
    # What one view is currently showing. The rendered HTML is kept because
    # toggling back to it must not refetch the document.
    Document = Struct.new(:url, :content, :rendered_html, :showing_source)
    private_constant :Document

    # @param content_fetcher [Adapters::ContentFetcher] Fetches document bytes
    def initialize(content_fetcher: Adapters::ContentFetcher.new)
      @content_fetcher = content_fetcher
      @documents = {}
    end

    # Does this URL name a document the browser renders itself?
    #
    # @param url [String, nil] URL to check
    # @return [Boolean]
    def markdown_url?(url)
      Domain::MarkdownDocument.markdown_url?(url)
    end

    # Fetches and renders a markdown document, and remembers it as what the
    # given view is showing.
    #
    # @param view_key [Object] Opaque identifier for the view
    # @param url [String] URL of the markdown document
    # @return [Domain::MarkdownView, nil] The page to display, or nil when
    #   there is nothing to render
    def render(view_key, url)
      return nil unless markdown_url?(url)

      content = fetch(url)
      return nil unless content

      html = Domain::MarkdownRenderer.render(content, url)
      @documents[view_key] = Document.new(url, content, html, false)

      Domain::MarkdownView.new(uri: url, html: html)
    end

    # Switches a view between the rendered document and its source.
    #
    # @param view_key [Object] Opaque identifier for the view
    # @return [Domain::MarkdownView, nil] The page to display, or nil when the
    #   view is not showing a markdown document
    def toggle_source(view_key)
      document = @documents[view_key]
      return nil unless document

      document.showing_source = !document.showing_source

      html = if document.showing_source
               Domain::MarkdownRenderer.render_source(document.content, document.url)
             else
               document.rendered_html
             end

      Domain::MarkdownView.new(uri: document.url, html: html)
    end

    # @param view_key [Object] Opaque identifier for the view
    # @return [Boolean] true when the view is showing a markdown document
    def showing_markdown?(view_key)
      @documents.key?(view_key)
    end

    # The markdown behind what a view is showing, for callers that need the
    # source rather than the rendering (the PDF bookmark pipeline).
    #
    # @param view_key [Object] Opaque identifier for the view
    # @return [String, nil] Raw markdown, or nil when the view shows none
    def source_content(view_key)
      @documents[view_key]&.content
    end

    # Drops what a view was showing, once it has navigated away.
    #
    # @param view_key [Object] Opaque identifier for the view
    def forget(view_key)
      @documents.delete(view_key)
    end

    private

    # A document that cannot be fetched is not an error the browser should
    # stop for: it reports the failure and lets the webview load the URL the
    # ordinary way.
    #
    # @param url [String] URL to fetch
    # @return [String, nil] Content, or nil when it could not be fetched
    def fetch(url)
      @content_fetcher.fetch(url)
    rescue StandardError => e
      warn "MarkdownManager: failed to fetch #{url}: #{e.message}"
      nil
    end
  end
end
