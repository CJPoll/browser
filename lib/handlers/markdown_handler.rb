require 'redcarpet'
require 'net/http'
require 'uri'
require 'cgi'
require 'set'

# Handles markdown file detection, rendering, and view toggling
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
# All callbacks are expected to run synchronously on the main thread.
class MarkdownHandler
  # State for the current markdown content
  MarkdownState = Struct.new(:uri, :raw_content, :rendered_html, :showing_raw, keyword_init: true)

  # Creates a new markdown handler
  def initialize
    @renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: '_blank' },
      with_toc_data: true  # Generate IDs for headings for TOC/anchor links
    )

    @markdown = Redcarpet::Markdown.new(@renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      underline: true,
      highlight: true,
      quote: true,
      footnotes: true,
      no_intra_emphasis: true
    )

    # Map from webview object_id to MarkdownState
    @states = {}

    # Track URLs currently being loaded to prevent infinite recursion
    # (load_html triggers decide-policy which would call us again)
    @loading = Set.new
  end

  # Checks if a URL points to a markdown file
  #
  # @param url [String] URL to check
  # @return [Boolean] true if URL is a markdown file
  def markdown_url?(url)
    return false unless url

    begin
      uri = URI.parse(url)
      path = uri.path.to_s.downcase

      # Check for .md or .markdown extension
      path.end_with?('.md') || path.end_with?('.markdown')
    rescue URI::InvalidURIError
      false
    end
  end

  # Handles navigation to a markdown URL
  # Fetches content and loads rendered HTML into the webview
  #
  # @param webview [WebKit2Gtk::WebView] The webview to load content into
  # @param url [String] The markdown file URL
  # @return [Boolean] true if handled, false if not a markdown URL
  def handle_navigation(webview, url)
    return false unless markdown_url?(url)

    # Prevent infinite recursion: load_html triggers decide-policy again
    return false if @loading.include?(url)

    # Fetch the markdown content
    content = fetch_content(url)
    return false unless content

    # Render to HTML
    rendered = render_to_html(content, url)

    # Store state for toggle functionality
    @states[webview.object_id] = MarkdownState.new(
      uri: url,
      raw_content: content,
      rendered_html: rendered,
      showing_raw: false
    )

    # Mark as loading to prevent recursion, then load the rendered HTML
    @loading.add(url)
    webview.load_html(rendered, url)
    # Clear loading flag after a short delay (GTK processes events synchronously)
    GLib::Idle.add do
      @loading.delete(url)
      false  # Don't repeat
    end

    true
  end

  # Toggles between rendered and raw markdown view
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [Boolean] true if toggled, false if no markdown state
  def toggle_view(webview)
    state = @states[webview.object_id]
    return false unless state

    # Mark as loading to prevent recursion
    @loading.add(state.uri)

    if state.showing_raw
      # Switch to rendered view
      webview.load_html(state.rendered_html, state.uri)
      state.showing_raw = false
    else
      # Switch to raw view
      raw_html = render_raw_view(state.raw_content, state.uri)
      webview.load_html(raw_html, state.uri)
      state.showing_raw = true
    end

    # Clear loading flag after GTK processes the load
    GLib::Idle.add do
      @loading.delete(state.uri)
      false  # Don't repeat
    end

    true
  end

  # Checks if the current page is showing markdown content
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [Boolean] true if showing markdown
  def showing_markdown?(webview)
    @states.key?(webview.object_id)
  end

  # Clears markdown state when navigating away
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  def clear_state(webview)
    @states.delete(webview.object_id)
  end

  # Gets the original markdown content for a webview
  #
  # @param webview [WebKit2Gtk::WebView] The webview
  # @return [String, nil] The markdown content or nil if not showing markdown
  def get_markdown_content(webview)
    state = @states[webview.object_id]
    state&.raw_content
  end

  private

  # Fetches content from a URL (file:// or http(s)://)
  #
  # @param url [String] The URL to fetch
  # @return [String, nil] Content or nil on error
  def fetch_content(url)
    begin
      uri = URI.parse(url)

      case uri.scheme
      when 'file'
        # Local file
        path = CGI.unescape(uri.path)
        return nil unless File.exist?(path)
        File.read(path, encoding: 'UTF-8')

      when 'http', 'https'
        # Remote file
        fetch_http_content(uri)

      else
        nil
      end
    rescue => e
      warn "MarkdownHandler: Failed to fetch #{url}: #{e.message}"
      nil
    end
  end

  # Fetches content from HTTP(S) URL
  #
  # @param uri [URI] Parsed URI
  # @return [String, nil] Content or nil on error
  def fetch_http_content(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request['User-Agent'] = 'Mozilla/5.0 (compatible; ToyBrowser/1.0)'

    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response.body.force_encoding('UTF-8')
    when Net::HTTPRedirection
      # Follow redirect (up to 1 level)
      fetch_http_content(URI.parse(response['location']))
    else
      nil
    end
  end

  # Renders markdown content to styled HTML
  #
  # @param content [String] Raw markdown content
  # @param url [String] Original URL for title
  # @return [String] Complete HTML document
  def render_to_html(content, url)
    # Parse title from first heading or filename
    title = extract_title(content, url)

    # Preprocess: convert page break markers to HTML
    content = process_page_breaks(content)

    # Render markdown to HTML body
    body_html = @markdown.render(content)

    # Check if content has mermaid diagrams
    has_mermaid = content.include?('```mermaid')

    # Convert mermaid code blocks to mermaid divs
    # Redcarpet renders ```mermaid as <pre><code class="mermaid">
    if has_mermaid
      body_html = convert_mermaid_blocks(body_html)
    end

    # Wrap in complete HTML document with styling
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>#{CGI.escapeHTML(title)}</title>
        <style>
          #{markdown_css}
        </style>
        #{mermaid_script if has_mermaid}
      </head>
      <body>
        <div class="markdown-body">
          #{body_html}
        </div>
        <div class="view-toggle">
          <span class="hint">Press Ctrl+U to view source</span>
        </div>
        #{mermaid_init_script if has_mermaid}
      </body>
      </html>
    HTML
  end

  # Renders raw markdown as HTML (pre-formatted)
  #
  # @param content [String] Raw markdown content
  # @param url [String] Original URL for title
  # @return [String] HTML document with raw content
  def render_raw_view(content, url)
    title = extract_title(content, url)

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>#{CGI.escapeHTML(title)} (Source)</title>
        <style>
          #{raw_view_css}
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

  # Extracts title from markdown content or URL
  #
  # @param content [String] Markdown content
  # @param url [String] URL
  # @return [String] Title
  def extract_title(content, url)
    # Try to find first heading
    if content =~ /^#\s+(.+?)$/
      return $1.strip
    end

    # Fall back to filename
    begin
      uri = URI.parse(url)
      path = CGI.unescape(uri.path)
      File.basename(path, '.*')
    rescue
      'Markdown'
    end
  end

  # CSS for rendered markdown view (GitHub-flavored styling)
  def markdown_css
    <<~CSS
      :root {
        color-scheme: light dark;
      }

      body {
        margin: 0;
        padding: 20px;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        font-size: 16px;
        line-height: 1.6;
        color: #24292f;
        background-color: #ffffff;
        min-height: 100vh;
      }

      @media (prefers-color-scheme: dark) {
        body {
          color: #c9d1d9;
          background-color: #0d1117;
        }
      }

      .markdown-body {
        max-width: 900px;
        margin: 0 auto;
        padding: 20px 40px;
      }

      h1, h2, h3, h4, h5, h6 {
        margin-top: 24px;
        margin-bottom: 16px;
        font-weight: 600;
        line-height: 1.25;
      }

      h1 {
        font-size: 2em;
        padding-bottom: 0.3em;
        border-bottom: 1px solid #d0d7de;
      }

      @media (prefers-color-scheme: dark) {
        h1 {
          border-bottom-color: #21262d;
        }
      }

      h2 {
        font-size: 1.5em;
        padding-bottom: 0.3em;
        border-bottom: 1px solid #d0d7de;
      }

      @media (prefers-color-scheme: dark) {
        h2 {
          border-bottom-color: #21262d;
        }
      }

      h3 { font-size: 1.25em; }
      h4 { font-size: 1em; }
      h5 { font-size: 0.875em; }
      h6 { font-size: 0.85em; color: #656d76; }

      p {
        margin-top: 0;
        margin-bottom: 16px;
      }

      a {
        color: #0969da;
        text-decoration: none;
      }

      a:hover {
        text-decoration: underline;
      }

      @media (prefers-color-scheme: dark) {
        a {
          color: #58a6ff;
        }
      }

      code {
        padding: 0.2em 0.4em;
        margin: 0;
        font-size: 85%;
        background-color: rgba(175, 184, 193, 0.2);
        border-radius: 6px;
        font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
      }

      pre {
        padding: 16px;
        overflow: auto;
        font-size: 85%;
        line-height: 1.45;
        background-color: #f6f8fa;
        border-radius: 6px;
      }

      @media (prefers-color-scheme: dark) {
        pre {
          background-color: #161b22;
        }
      }

      pre code {
        padding: 0;
        margin: 0;
        font-size: 100%;
        background-color: transparent;
        border: 0;
      }

      blockquote {
        padding: 0 1em;
        color: #656d76;
        border-left: 0.25em solid #d0d7de;
        margin: 0 0 16px 0;
      }

      @media (prefers-color-scheme: dark) {
        blockquote {
          color: #8b949e;
          border-left-color: #3b434b;
        }
      }

      ul, ol {
        padding-left: 2em;
        margin-top: 0;
        margin-bottom: 16px;
      }

      li {
        margin-top: 0.25em;
      }

      table {
        border-spacing: 0;
        border-collapse: collapse;
        margin-bottom: 16px;
        width: max-content;
        max-width: 100%;
        overflow: auto;
      }

      table th, table td {
        padding: 6px 13px;
        border: 1px solid #d0d7de;
      }

      @media (prefers-color-scheme: dark) {
        table th, table td {
          border-color: #3b434b;
        }
      }

      table th {
        font-weight: 600;
        background-color: #f6f8fa;
      }

      @media (prefers-color-scheme: dark) {
        table th {
          background-color: #161b22;
        }
      }

      table tr:nth-child(2n) {
        background-color: #f6f8fa;
      }

      @media (prefers-color-scheme: dark) {
        table tr:nth-child(2n) {
          background-color: #161b22;
        }
      }

      hr {
        height: 0.25em;
        padding: 0;
        margin: 24px 0;
        background-color: #d0d7de;
        border: 0;
      }

      @media (prefers-color-scheme: dark) {
        hr {
          background-color: #21262d;
        }
      }

      img {
        max-width: 100%;
        box-sizing: border-box;
      }

      /* Page break markers - invisible on screen, active in print */
      .page-break {
        display: none;
      }

      .view-toggle {
        position: fixed;
        bottom: 10px;
        right: 10px;
        padding: 8px 12px;
        background-color: rgba(0, 0, 0, 0.7);
        color: #ffffff;
        border-radius: 4px;
        font-size: 12px;
        opacity: 0.5;
        transition: opacity 0.2s;
      }

      .view-toggle:hover {
        opacity: 1;
      }

      @media (prefers-color-scheme: dark) {
        .view-toggle {
          background-color: rgba(255, 255, 255, 0.2);
        }
      }

      /* Print styles for PDF export - preserve dark theme */
      @media print {
        * {
          -webkit-print-color-adjust: exact !important;
          print-color-adjust: exact !important;
          color-adjust: exact !important;
        }

        @page {
          size: auto;
          margin: 0mm;
        }

        html {
          background-color: #0d1117 !important;
        }

        body {
          min-height: 100vh;
          background-color: #0d1117 !important;
        }

        body::after {
          content: "";
          display: block;
          height: 100vh;
          background-color: #0d1117 !important;
        }

        /* Apply dark theme text color to markdown content, but not mermaid diagrams */
        .markdown-body {
          color: #c9d1d9 !important;
        }

        /* PDF bookmark hints - heading hierarchy */
        h1 {
          -webkit-bookmark-level: 1;
          bookmark-level: 1;
        }

        h2 {
          -webkit-bookmark-level: 2;
          bookmark-level: 2;
        }

        h3 {
          -webkit-bookmark-level: 3;
          bookmark-level: 3;
        }

        h4 {
          -webkit-bookmark-level: 4;
          bookmark-level: 4;
        }

        h5 {
          -webkit-bookmark-level: 5;
          bookmark-level: 5;
        }

        h6 {
          -webkit-bookmark-level: 6;
          bookmark-level: 6;
        }

        /* Prevent links from breaking across pages */
        a {
          page-break-inside: avoid;
        }

        .view-toggle {
          display: none;
        }

        .markdown-body {
          max-width: 900px;
          margin: 0 auto;
        }

        h1, h2, h3, h4, h5, h6 {
          color: #c9d1d9 !important;
          page-break-after: avoid;
        }

        h1 {
          border-bottom-color: #21262d !important;
        }

        h2 {
          border-bottom-color: #21262d !important;
        }

        h6 {
          color: #8b949e !important;
        }

        a {
          color: #58a6ff !important;
        }

        code {
          background-color: rgba(175, 184, 193, 0.2) !important;
        }

        pre {
          background-color: #161b22 !important;
          page-break-inside: avoid;
        }

        blockquote {
          color: #8b949e !important;
          border-left-color: #3b434b !important;
          page-break-inside: avoid;
        }

        table {
          page-break-inside: avoid;
        }

        table th, table td {
          border-color: #3b434b !important;
        }

        table th {
          background-color: #161b22 !important;
        }

        table tr:nth-child(2n) {
          background-color: #161b22 !important;
        }

        hr {
          background-color: #21262d !important;
        }

        /* Ensure mermaid diagrams render in print */
        .mermaid {
          page-break-inside: avoid;
        }

        /* Don't inherit markdown's grey text color - let mermaid theme control colors */
        .mermaid,
        .mermaid * {
          color: revert !important;
        }

        .mermaid svg {
          max-width: 100% !important;
          height: auto !important;
        }

        /* Page break support for PDF export */
        .page-break {
          page-break-after: always;
          break-after: page;
          display: block;
          height: 0;
          margin: 0;
          padding: 0;
          border: 0;
          visibility: hidden;
        }

        /* Alternative: horizontal rules as page breaks */
        hr.page-break {
          page-break-after: always;
          break-after: page;
          visibility: hidden;
          margin: 0;
          padding: 0;
          height: 0;
        }
      }
    CSS
  end

  # CSS for raw markdown view
  def raw_view_css
    <<~CSS
      :root {
        color-scheme: light dark;
      }

      body {
        margin: 0;
        padding: 20px;
        font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
        font-size: 14px;
        line-height: 1.5;
        color: #24292f;
        background-color: #f6f8fa;
      }

      @media (prefers-color-scheme: dark) {
        body {
          color: #c9d1d9;
          background-color: #0d1117;
        }
      }

      .raw-body {
        max-width: 1200px;
        margin: 0 auto;
        padding: 20px;
      }

      pre {
        margin: 0;
        white-space: pre-wrap;
        word-wrap: break-word;
      }

      code {
        font-family: inherit;
      }

      .view-toggle {
        position: fixed;
        bottom: 10px;
        right: 10px;
        padding: 8px 12px;
        background-color: rgba(0, 0, 0, 0.7);
        color: #ffffff;
        border-radius: 4px;
        font-size: 12px;
        opacity: 0.5;
        transition: opacity 0.2s;
      }

      .view-toggle:hover {
        opacity: 1;
      }

      @media (prefers-color-scheme: dark) {
        .view-toggle {
          background-color: rgba(255, 255, 255, 0.2);
        }
      }
    CSS
  end

  # Processes page break markers in markdown content
  # Converts HTML comments to page break divs
  #
  # Supported formats:
  # - <!-- pagebreak -->
  # - <!-- page-break -->
  # - <!-- PAGEBREAK -->
  #
  # @param content [String] Raw markdown content
  # @return [String] Markdown with page break divs
  def process_page_breaks(content)
    # Convert HTML comments to page break divs
    # Match case-insensitive variants with optional hyphens/spaces
    content.gsub(/<!--\s*page[\s\-_]?break\s*-->/i, '<div class="page-break"></div>')
  end

  # Converts mermaid code blocks to mermaid divs
  # Redcarpet renders ```mermaid as <pre><code class="mermaid">content</code></pre>
  # Mermaid.js expects <pre class="mermaid">content</pre>
  #
  # @param html [String] HTML with mermaid code blocks
  # @return [String] HTML with converted mermaid divs
  def convert_mermaid_blocks(html)
    # Match <pre><code class="mermaid">content</code></pre>
    # and convert to <pre class="mermaid">content</pre>
    html.gsub(/<pre><code class="mermaid">(.*?)<\/code><\/pre>/m) do |_match|
      content = $1
      # Unescape HTML entities that redcarpet escaped
      content = CGI.unescapeHTML(content)
      %(<pre class="mermaid">#{content}</pre>)
    end
  end

  # Returns the Mermaid.js script tag
  def mermaid_script
    <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    HTML
  end

  # Returns the Mermaid initialization script
  def mermaid_init_script
    <<~HTML
      <script>
        (function() {
          let isPrinting = false;
          let renderedDiagrams = new Map();

          // Fix text colors on light-colored nodes (pink, green, yellow, etc.)
          function fixLightNodeTextColors() {
            console.log('[TextFix] Starting text color fix...');

            // Group shapes by parent node and find the lightest color in each node
            const nodeMap = new Map(); // parent element -> max luminance

            document.querySelectorAll('.mermaid svg rect, .mermaid svg path').forEach(function(shape) {
              // Get computed fill color
              const computedFill = window.getComputedStyle(shape).fill;
              const attrFill = shape.getAttribute('fill');
              let fill = computedFill || attrFill;

              if (!fill || fill === 'none' || fill === 'transparent') return;
              fill = String(fill);

              // Parse color to RGB
              let r = 0, g = 0, b = 0;

              if (fill.startsWith('rgb')) {
                const matches = fill.match(/[0-9]+/g);
                if (matches && matches.length >= 3) {
                  r = parseInt(matches[0]);
                  g = parseInt(matches[1]);
                  b = parseInt(matches[2]);
                }
              } else if (fill.startsWith('#')) {
                const hex = fill.substring(1);
                r = parseInt(hex.substr(0, 2), 16);
                g = parseInt(hex.substr(2, 2), 16);
                b = parseInt(hex.substr(4, 2), 16);
              } else if (fill.startsWith('hsl')) {
                const matches = fill.match(/([0-9.]+)/g);
                if (matches && matches.length >= 3) {
                  const h = parseFloat(matches[0]);
                  const s = parseFloat(matches[1]) / 100;
                  const l = parseFloat(matches[2]) / 100;

                  const c = (1 - Math.abs(2 * l - 1)) * s;
                  const x = c * (1 - Math.abs((h / 60) % 2 - 1));
                  const m = l - c / 2;

                  let r1, g1, b1;
                  if (h < 60) { r1 = c; g1 = x; b1 = 0; }
                  else if (h < 120) { r1 = x; g1 = c; b1 = 0; }
                  else if (h < 180) { r1 = 0; g1 = c; b1 = x; }
                  else if (h < 240) { r1 = 0; g1 = x; b1 = c; }
                  else if (h < 300) { r1 = x; g1 = 0; b1 = c; }
                  else { r1 = c; g1 = 0; b1 = x; }

                  r = Math.round((r1 + m) * 255);
                  g = Math.round((g1 + m) * 255);
                  b = Math.round((b1 + m) * 255);
                }
              }

              // Calculate relative luminance
              const luminance = (0.299 * r + 0.587 * g + 0.114 * b);

              // Find parent node group
              let parent = shape.parentElement;
              while (parent && !parent.classList.contains('node') && parent.tagName !== 'g') {
                parent = parent.parentElement;
              }

              if (parent) {
                // Track the maximum luminance for this node (lightest color = background)
                const currentMax = nodeMap.get(parent) || 0;
                if (luminance > currentMax) {
                  nodeMap.set(parent, luminance);
                  console.log('[TextFix] Node max luminance:', luminance, 'from', fill);
                }
              }
            });

            // Track which text elements we've seen and their luminance
            const textLuminanceMap = new Map(); // text element -> luminance

            // Now apply text colors based on the lightest color in each node
            nodeMap.forEach(function(maxLuminance, parent) {
              const texts = parent.querySelectorAll('text, tspan, foreignObject, foreignObject *');

              texts.forEach(function(text) {
                // Only update if we haven't seen this text, or if this luminance is higher
                const existingLuminance = textLuminanceMap.get(text);
                if (existingLuminance === undefined || maxLuminance > existingLuminance) {
                  textLuminanceMap.set(text, maxLuminance);

                  const isLight = maxLuminance > 128;
                  if (isLight) {
                    text.style.fill = '#000000';
                    text.style.color = '#000000';
                  } else {
                    text.style.fill = '#cccccc';
                    text.style.color = '#cccccc';
                  }
                }
              });
            });

            console.log('[TextFix] Text color fix complete -', textLuminanceMap.size, 'text elements processed from', nodeMap.size, 'nodes');
          }

          document.addEventListener('DOMContentLoaded', function() {
            // Detect dark mode
            const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;

            mermaid.initialize({
              startOnLoad: true,
              theme: isDark ? 'dark' : 'default',
              securityLevel: 'loose',
              logLevel: 'error',
              flowchart: {
                useMaxWidth: true,
                htmlLabels: true,
                curve: 'basis'
              }
            });

            // Watch for mermaid diagrams being added/modified
            const observer = new MutationObserver(function(mutations) {
              mutations.forEach(function(mutation) {
                if (mutation.type === 'childList' || mutation.type === 'attributes') {
                  // Check if any mermaid diagrams are now rendered
                  const processedDiagrams = document.querySelectorAll('.mermaid[data-processed="true"]');
                  if (processedDiagrams.length > 0) {
                    console.log('[TextFix] Detected rendered mermaid diagrams, fixing text colors...');
                    fixLightNodeTextColors();
                  }
                }
              });
            });

            // Observe all mermaid elements
            document.querySelectorAll('.mermaid').forEach(function(el) {
              observer.observe(el, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['data-processed']
              });
            });

            // Also use timeouts as backup
            setTimeout(function() {
              fixLightNodeTextColors();
              document.querySelectorAll('.mermaid[data-processed="true"]').forEach(function(el) {
                renderedDiagrams.set(el, el.cloneNode(true));
              });
            }, 1000);

            // Before print: protect rendered diagrams
            window.addEventListener('beforeprint', function() {
              isPrinting = true;
              // Save current state of all diagrams
              document.querySelectorAll('.mermaid[data-processed="true"]').forEach(function(el) {
                renderedDiagrams.set(el, el.cloneNode(true));
              });
            });

            // After print: restore diagrams if they broke
            window.addEventListener('afterprint', function() {
              isPrinting = false;
              // Check if any diagrams broke and restore them
              setTimeout(function() {
                document.querySelectorAll('.mermaid').forEach(function(el) {
                  // If diagram shows error or lost its content, restore from saved version
                  if (el.textContent.includes('Syntax error') || !el.querySelector('svg')) {
                    const saved = renderedDiagrams.get(el);
                    if (saved) {
                      el.innerHTML = saved.innerHTML;
                      el.setAttribute('data-processed', 'true');
                    }
                  }
                });
                fixLightNodeTextColors();
              }, 100);
            });

            // Re-initialize on theme change (but not during printing)
            window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
              if (!isPrinting) {
                mermaid.initialize({
                  theme: e.matches ? 'dark' : 'default'
                });
                // Re-render diagrams
                document.querySelectorAll('.mermaid').forEach(function(el) {
                  el.removeAttribute('data-processed');
                });
                mermaid.init();
                // Save new rendered state and fix text colors
                setTimeout(function() {
                  fixLightNodeTextColors();
                  document.querySelectorAll('.mermaid[data-processed="true"]').forEach(function(el) {
                    renderedDiagrams.set(el, el.cloneNode(true));
                  });
                }, 1000);
              }
            });
          });
        })();
      </script>
    HTML
  end
end
