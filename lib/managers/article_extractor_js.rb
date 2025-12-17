# JavaScript-based article content extractor
#
# This module generates JavaScript code that extracts article content
# directly in the browser's JavaScript engine, avoiding Ruby GC conflicts
# with Nokogiri and libxml2.
#
# The extraction uses similar heuristics to Readability.js:
# - Remove nav, header, footer, sidebar, ads
# - Find main article content using semantic selectors
# - Fall back to finding the element with the most paragraph content
module ArticleExtractorJS
  # Returns JavaScript code that extracts article content and returns JSON
  #
  # The script returns a JSON string with:
  #   { "title": "...", "content": "..." }
  #
  # @return [String] JavaScript code to execute
  def self.extraction_script
    <<~JAVASCRIPT
      (function() {
        // Elements to remove (navigation, ads, etc.)
        const REMOVABLE_SELECTORS = [
          'nav', 'header', 'footer', 'aside',
          '.sidebar', '.navigation', '.nav', '.menu',
          '.advertisement', '.ad', '.ads', '.social', '.share',
          '.comments', '.comment', '.related', '.recommended',
          '.toc', '.table-of-contents', '.mw-jump-link',
          '#sidebar', '#navigation', '#nav', '#menu',
          '#comments', '#footer', '#header', '#toc',
          '#mw-navigation', '#mw-panel', '#mw-head',
          '.navbox', '.catlinks', '.reflist', '.references',
          '.mw-editsection', '.mw-indicators', '.sistersitebox',
          '[role="navigation"]', '[role="banner"]',
          '[role="complementary"]', '[role="contentinfo"]',
          '.vector-toc', '.vector-menu', '.vector-header',
          '.infobox', '.thumb', '.hatnote'
        ];

        // Selectors for article content (in order of preference)
        const CONTENT_SELECTORS = [
          '#mw-content-text .mw-parser-output',  // Wikipedia
          '#mw-content-text',  // Wikipedia fallback
          'article', '[role="main"]', '[role="article"]',
          '.article', '.post', '.entry', '.content',
          '.post-content', '.article-content', '.entry-content',
          '.story', 'main', '#content', '#article', '#main'
        ];

        // Extract title
        function extractTitle() {
          // 1. og:title meta tag
          const ogTitle = document.querySelector('meta[property="og:title"]');
          if (ogTitle && ogTitle.content) {
            return ogTitle.content.trim();
          }

          // 2. Wikipedia specific - first heading
          const wikiTitle = document.querySelector('#firstHeading, .mw-page-title-main');
          if (wikiTitle && wikiTitle.textContent.trim()) {
            return wikiTitle.textContent.trim();
          }

          // 3. First h1 in article
          const article = document.querySelector('article, [role="main"], main');
          if (article) {
            const h1 = article.querySelector('h1');
            if (h1 && h1.textContent.trim()) {
              return h1.textContent.trim();
            }
          }

          // 4. First h1 on page
          const h1 = document.querySelector('h1');
          if (h1 && h1.textContent.trim()) {
            return h1.textContent.trim();
          }

          // 5. Title tag (remove site name suffix)
          const titleTag = document.querySelector('title');
          if (titleTag) {
            let title = titleTag.textContent.trim();
            title = title.split(/\\s*[|\\-–—]\\s*/)[0];
            if (title) return title.trim();
          }

          return null;
        }

        // Check if element should be excluded
        function shouldExclude(element) {
          if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;

          // Check for data-reader-exclude marker
          if (element.getAttribute('data-reader-exclude') === 'true') return true;

          // Check common navigation/utility class patterns
          const className = element.className || '';
          const id = element.id || '';
          const combined = (className + ' ' + id).toLowerCase();

          const excludePatterns = [
            'nav', 'menu', 'sidebar', 'footer', 'header',
            'toc', 'reference', 'citation', 'edit', 'lang',
            'interlanguage', 'catlink', 'navbox', 'infobox'
          ];

          for (const pattern of excludePatterns) {
            if (combined.includes(pattern)) return true;
          }

          return false;
        }

        // Check if element has substantial content
        function hasSubstantialContent(element) {
          const paragraphs = element.querySelectorAll('p');
          if (paragraphs.length < 2) return false;
          return element.textContent.trim().length > 500;
        }

        // Find element with most paragraph content
        function findContentRichElement() {
          const candidates = [];

          document.querySelectorAll('div, section, article').forEach(element => {
            if (shouldExclude(element)) return;

            const paragraphs = element.querySelectorAll('p');
            if (paragraphs.length < 3) return;

            // Calculate text from paragraphs only (not all text)
            let textLength = 0;
            paragraphs.forEach(p => {
              if (!shouldExclude(p)) {
                textLength += p.textContent.trim().length;
              }
            });

            if (textLength < 500) return;

            // Calculate link density
            let linkTextLength = 0;
            element.querySelectorAll('a').forEach(a => {
              linkTextLength += a.textContent.trim().length;
            });

            const linkDensity = textLength > 0 ? linkTextLength / textLength : 1.0;
            if (linkDensity > 0.4) return;

            const score = paragraphs.length * 10 + textLength;
            candidates.push({ element, score });
          });

          if (candidates.length === 0) return null;

          candidates.sort((a, b) => b.score - a.score);
          return candidates[0].element;
        }

        // Extract readable text from paragraphs and headings only
        function extractReadableText(element) {
          const lines = [];
          const seen = new Set();

          // Only process direct content elements, not all descendants
          function processElement(el) {
            if (shouldExclude(el)) return;

            const tagName = el.tagName.toLowerCase();

            // Process headings
            if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].includes(tagName)) {
              const text = el.textContent.trim();
              // Skip edit links in headings
              const cleanText = text.replace(/\\[edit\\]/gi, '').trim();
              if (cleanText && !seen.has(cleanText)) {
                seen.add(cleanText);
                lines.push('');
                lines.push(cleanText);
                lines.push('');
              }
              return;
            }

            // Process paragraphs
            if (tagName === 'p') {
              const text = el.textContent.trim();
              if (text && text.length > 20 && !seen.has(text)) {
                seen.add(text);
                lines.push(text);
                lines.push('');
              }
              return;
            }

            // Process lists
            if (tagName === 'ul' || tagName === 'ol') {
              const items = el.querySelectorAll(':scope > li');
              if (items.length > 0 && items.length < 20) {  // Skip huge lists (likely navigation)
                items.forEach(li => {
                  if (!shouldExclude(li)) {
                    const text = li.textContent.trim();
                    if (text && text.length > 10 && text.length < 500) {
                      lines.push('  • ' + text);
                    }
                  }
                });
                lines.push('');
              }
              return;
            }

            // Process blockquotes
            if (tagName === 'blockquote') {
              const text = el.textContent.trim();
              if (text && !seen.has(text)) {
                seen.add(text);
                lines.push('  ' + text.replace(/\\n/g, '\\n  '));
                lines.push('');
              }
              return;
            }

            // Recurse into divs and sections, but only for semantic containers
            if (['div', 'section', 'article', 'main'].includes(tagName)) {
              el.querySelectorAll(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6, :scope > p, :scope > ul, :scope > ol, :scope > blockquote, :scope > div, :scope > section').forEach(child => {
                processElement(child);
              });
            }
          }

          processElement(element);

          // Clean up
          return lines.join('\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
        }

        // Mark elements for exclusion
        function prepareDocument() {
          REMOVABLE_SELECTORS.forEach(selector => {
            try {
              document.querySelectorAll(selector).forEach(el => {
                el.setAttribute('data-reader-exclude', 'true');
              });
            } catch (e) {
              // Invalid selector, skip
            }
          });

          // Mark scripts, styles, hidden elements
          document.querySelectorAll('script, style, noscript, [hidden], [aria-hidden="true"]').forEach(el => {
            el.setAttribute('data-reader-exclude', 'true');
          });
        }

        // Main extraction function
        function extractContent() {
          prepareDocument();

          // Try content selectors
          for (const selector of CONTENT_SELECTORS) {
            try {
              const element = document.querySelector(selector);
              if (element && !shouldExclude(element) && hasSubstantialContent(element)) {
                return extractReadableText(element);
              }
            } catch (e) {
              // Invalid selector, skip
            }
          }

          // Fallback: find content-rich element
          const richElement = findContentRichElement();
          if (richElement) {
            return extractReadableText(richElement);
          }

          return null;
        }

        // Extract and return result
        const result = {
          title: extractTitle(),
          content: extractContent()
        };

        // Clean up markers
        document.querySelectorAll('[data-reader-exclude]').forEach(el => {
          el.removeAttribute('data-reader-exclude');
        });

        return JSON.stringify(result);
      })();
    JAVASCRIPT
  end
end
