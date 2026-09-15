# frozen_string_literal: true

require 'cgi'

module Domain
  # The page a tab shows in place of content whose web process died.
  #
  # WebKit runs page content in a separate process, so that process crashing
  # costs one tab rather than the browser. Nothing was showing that before:
  # the tab went blank and the reason was only ever written to stderr.
  #
  # A constant payload behind a method, following the Domain::MarkdownStyles /
  # Domain::VideoPopoutStyles precedent -- producing it reads nothing.
  module CrashPage
    # What WebKit says happened, mapped to what the page says about it.
    #
    # The Framework hands over the reason as a plain string (WebKit's enum
    # nickname) rather than the enum itself, so naming a WebKit type stays out
    # of Domain.
    REASONS = {
      crashed: 'The page crashed.',
      exceeded_memory_limit: 'The page used more memory than it was allowed.',
      terminated_by_api: 'The page was stopped by the browser.',
      unknown: 'The page stopped running.'
    }.freeze

    # Canonical form of a termination reason
    #
    # An unrecognised reason is a decision, not an error: a WebKit version that
    # grows a fourth reason gets the generic sentence rather than an exception
    # inside a signal handler.
    #
    # @param reason [String, Symbol, nil] WebKit's reason, e.g. "exceeded-memory-limit"
    # @return [Symbol] One of REASONS' keys
    def self.normalize(reason)
      key = reason.to_s.strip.downcase.tr('-', '_').to_sym
      REASONS.key?(key) ? key : :unknown
    end

    # One sentence saying what happened
    #
    # @param reason [String, Symbol, nil] WebKit's reason
    # @return [String] Human-readable explanation
    def self.describe(reason)
      REASONS.fetch(normalize(reason))
    end

    # A single line for the log, naming the tab that died
    #
    # @param url [String, nil] URL the tab was showing
    # @param reason [String, Symbol, nil] WebKit's reason
    # @return [String] Log line, without a trailing newline
    def self.log_line(url:, reason:)
      "Web process terminated (#{normalize(reason)}): #{present?(url) ? url : '<no url>'}"
    end

    # Renders the page shown in the crashed tab
    #
    # @param url [String, nil] URL the tab was showing, offered as a retry link
    # @param reason [String, Symbol, nil] WebKit's reason
    # @return [String] HTML document
    def self.html(url:, reason:)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Page crashed</title>
          <style>
            #{css}
          </style>
        </head>
        <body>
          <div class="crash">
            <div class="icon">&#9888;</div>
            <h1>#{CGI.escapeHTML(describe(reason))}</h1>
            <p class="detail">The rest of the browser is unaffected. Reloading usually brings it back.</p>
            #{url_section(url)}
          </div>
        </body>
        </html>
      HTML
    end

    # The retry link, omitted for a tab that never got a URL
    #
    # @param url [String, nil] URL the tab was showing
    # @return [String] HTML fragment
    def self.url_section(url)
      return '' unless present?(url)

      escaped = CGI.escapeHTML(url)
      <<~HTML.strip
        <p class="url">#{escaped}</p>
        <a class="reload" href="#{escaped}">Reload page</a>
      HTML
    end

    # @return [Boolean] Whether there is a URL worth naming
    def self.present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
    private_class_method :present?

    # Styling for the crash page, dark-mode aware like the markdown pages
    #
    # @return [String] CSS
    def self.css
      <<~CSS
        :root { color-scheme: light dark; }

        body {
          margin: 0;
          min-height: 100vh;
          display: flex;
          align-items: center;
          justify-content: center;
          font-family: -apple-system, "Segoe UI", "Cantarell", "Helvetica Neue", sans-serif;
          background: #ffffff;
          color: #24292f;
        }

        .crash {
          max-width: 34rem;
          padding: 2rem;
          text-align: center;
        }

        .icon {
          font-size: 3rem;
          line-height: 1;
          color: #9a6700;
        }

        h1 {
          margin: 1rem 0 0.5rem;
          font-size: 1.4rem;
          font-weight: 600;
        }

        .detail {
          margin: 0 0 1.5rem;
          color: #57606a;
        }

        .url {
          margin: 0 0 1.5rem;
          padding: 0.5rem 0.75rem;
          border-radius: 6px;
          background: #f6f8fa;
          font-family: ui-monospace, "SFMono-Regular", monospace;
          font-size: 0.85rem;
          color: #57606a;
          word-break: break-all;
        }

        .reload {
          display: inline-block;
          padding: 0.5rem 1.25rem;
          border-radius: 6px;
          background: #1f6feb;
          color: #ffffff;
          font-weight: 500;
          text-decoration: none;
        }

        .reload:hover { background: #1a5fd0; }

        @media (prefers-color-scheme: dark) {
          body { background: #0d1117; color: #e6edf3; }
          .icon { color: #d29922; }
          .detail { color: #8b949e; }
          .url { background: #161b22; color: #8b949e; }
        }
      CSS
    end
  end
end
