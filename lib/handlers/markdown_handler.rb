# frozen_string_literal: true

require 'set'
require_relative '../managers/markdown_manager'

# Renders markdown files in a webview instead of letting WebKit download or
# display them raw.
#
# Framework: it intercepts the navigation, asks the manager what to show, and
# loads the result. Fetching, rendering and the rendered/source state all live
# behind Managers::MarkdownManager.
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
# All callbacks are expected to run synchronously on the main thread.
class MarkdownHandler
  # Clearing the recursion guard has to wait until WebKit has processed the
  # load we just started, which means the GTK main loop. Injected so tests can
  # run the work without one.
  MAIN_THREAD_SCHEDULER = lambda do |&block|
    GLib::Idle.add do
      block.call
      false # Don't repeat
    end
  end

  # @param manager [Managers::MarkdownManager] Renders documents and remembers
  #   which view each webview is showing
  # @param scheduler [#call] Runs a block on the main loop
  def initialize(manager: Managers::MarkdownManager.new, scheduler: MAIN_THREAD_SCHEDULER)
    @manager = manager
    @scheduler = scheduler

    # URLs whose rendered HTML is being loaded right now. Loading it makes
    # WebKit ask about the same URL again, and rendering it a second time
    # would refetch the document and recurse.
    @loading = Set.new
  end

  # Checks if a URL points to a markdown file
  #
  # @param url [String] URL to check
  # @return [Boolean] true if URL is a markdown file
  def markdown_url?(url)
    @manager.markdown_url?(url)
  end

  # Handles navigation to a markdown URL
  # Fetches content and loads rendered HTML into the webview
  #
  # @param webview [WebKit2Gtk::WebView] The webview to load content into
  # @param url [String] The markdown file URL
  # @return [Boolean] true if handled, false if not a markdown URL
  def handle_navigation(webview, url)
    return false unless @manager.markdown_url?(url)
    return false if @loading.include?(url)

    view = @manager.render(view_key(webview), url)
    return false unless view

    display(webview, view)
    true
  end

  # Toggles between rendered and raw markdown view
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [Boolean] true if toggled, false if no markdown state
  def toggle_view(webview)
    view = @manager.toggle_source(view_key(webview))
    return false unless view

    display(webview, view)
    true
  end

  # Checks if the current page is showing markdown content
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [Boolean] true if showing markdown
  def showing_markdown?(webview)
    @manager.showing_markdown?(view_key(webview))
  end

  # Clears markdown state when navigating away
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  def clear_state(webview)
    @manager.forget(view_key(webview))
  end

  # Gets the original markdown content for a webview
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [String, nil] The markdown content or nil if not showing markdown
  def get_markdown_content(webview)
    @manager.source_content(view_key(webview))
  end

  private

  # @param webview [WebKit2Gtk::WebView] The webview
  # @param view [Domain::MarkdownView] The page to display
  def display(webview, view)
    @loading.add(view.uri)
    webview.load_html(view.html, view.uri)
    @scheduler.call { @loading.delete(view.uri) }
  end

  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [Integer] Key naming this webview to the manager
  def view_key(webview)
    webview.object_id
  end
end
