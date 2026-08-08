# frozen_string_literal: true

module Domain
  # The Mermaid.js payloads a rendered markdown document carries when it
  # contains a diagram.
  #
  # Deterministic content rather than a file read at runtime, following the
  # Domain::ArticleExtractorJS precedent.
  module MermaidScript
    # The script tag that loads Mermaid.js from its CDN.
    #
    # @return [String] HTML
    def self.library_tag
      <<~HTML
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
      HTML
    end

    # The script that initialises Mermaid, follows the system's colour
    # scheme, and restores diagrams that printing has broken.
    #
    # @return [String] HTML
    def self.init_script
      <<~HTML
        <script>
          (function() {
            let isPrinting = false;
            let renderedDiagrams = new Map();

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

              // Save rendered diagrams after they load
              setTimeout(function() {
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
                  // Save new rendered state
                  setTimeout(function() {
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
end
