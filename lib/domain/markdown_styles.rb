# frozen_string_literal: true

module Domain
  # The stylesheets the browser wraps a markdown document in.
  #
  # Deterministic content rather than a file read at runtime, following the
  # Domain::ArticleExtractorJS precedent.
  module MarkdownStyles
    # GitHub-flavoured styling for the rendered view, including the print
    # rules the PDF export depends on: the dark theme, the heading bookmark
    # levels and the page-break element.
    #
    # @return [String] CSS
    def self.rendered_css
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
            font-size: 90% !important;
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

    # Styling for the source view (Ctrl+U).
    #
    # @return [String] CSS
    def self.raw_css
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
  end
end
