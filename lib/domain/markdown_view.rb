# frozen_string_literal: true

module Domain
  # A page the browser renders itself and shows in place of what the webview
  # would otherwise have loaded: the HTML, and the URI it stands for (so the
  # address bar and relative links still refer to the original document).
  MarkdownView = Struct.new(:uri, :html, keyword_init: true)
end
