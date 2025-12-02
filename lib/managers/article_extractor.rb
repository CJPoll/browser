require 'nokogiri'

# Extracts article content from HTML pages
#
# Uses heuristics to identify the main article content and remove
# navigation, sidebars, ads, and other non-content elements.
class ArticleExtractor
  # Elements that typically contain navigation/chrome, not content
  REMOVABLE_SELECTORS = %w[
    nav
    header
    footer
    aside
    .sidebar
    .navigation
    .nav
    .menu
    .advertisement
    .ad
    .ads
    .social
    .share
    .comments
    .comment
    .related
    .recommended
    #sidebar
    #navigation
    #nav
    #menu
    #comments
    #footer
    #header
    [role="navigation"]
    [role="banner"]
    [role="complementary"]
    [role="contentinfo"]
  ].freeze

  # Elements that likely contain article content
  CONTENT_SELECTORS = %w[
    article
    [role="main"]
    [role="article"]
    .article
    .post
    .entry
    .content
    .post-content
    .article-content
    .entry-content
    .story
    main
    #content
    #article
    #main
  ].freeze

  # Extracts article content from HTML
  #
  # @param html [String] Full HTML of the page
  # @return [Hash] Hash with :title and :content keys
  def extract(html)
    return { title: nil, content: nil } if html.nil? || html.empty?

    doc = Nokogiri::HTML(html)

    title = extract_title(doc)
    content = extract_content(doc)

    { title: title, content: content }
  end

  private

  # Extracts the article title
  #
  # @param doc [Nokogiri::HTML::Document] Parsed HTML document
  # @return [String, nil] Article title
  def extract_title(doc)
    # Try various title sources in order of preference

    # 1. og:title meta tag (often cleanest)
    og_title = doc.at_css('meta[property="og:title"]')&.[]('content')
    return og_title.strip if og_title && !og_title.empty?

    # 2. First h1 in article
    article = doc.at_css('article, [role="main"], main')
    if article
      h1 = article.at_css('h1')
      return h1.text.strip if h1 && !h1.text.strip.empty?
    end

    # 3. First h1 on page
    h1 = doc.at_css('h1')
    return h1.text.strip if h1 && !h1.text.strip.empty?

    # 4. Title tag (often includes site name)
    title_tag = doc.at_css('title')
    if title_tag
      title = title_tag.text.strip
      # Try to remove site name suffix (e.g., "Article Title - Site Name")
      title = title.split(/\s*[|\-–—]\s*/).first
      return title.strip if title && !title.empty?
    end

    nil
  end

  # Extracts the main article content
  #
  # @param doc [Nokogiri::HTML::Document] Parsed HTML document
  # @return [String, nil] Article content as HTML
  def extract_content(doc)
    # Remove unwanted elements first
    REMOVABLE_SELECTORS.each do |selector|
      doc.css(selector).each(&:remove)
    end

    # Remove script, style, and hidden elements
    doc.css('script, style, noscript, [hidden], [aria-hidden="true"]').each(&:remove)

    # Try to find article content using content selectors
    CONTENT_SELECTORS.each do |selector|
      element = doc.at_css(selector)
      if element && substantial_content?(element)
        return clean_content(element)
      end
    end

    # Fallback: find the element with the most paragraph text
    best_element = find_content_rich_element(doc)
    return clean_content(best_element) if best_element

    # Last resort: body content
    body = doc.at_css('body')
    body ? clean_content(body) : nil
  end

  # Checks if an element has substantial content
  #
  # @param element [Nokogiri::XML::Element] Element to check
  # @return [Boolean] True if element has substantial content
  def substantial_content?(element)
    # Count paragraphs and text length
    paragraphs = element.css('p')
    return false if paragraphs.length < 2

    text_length = element.text.strip.length
    text_length > 500
  end

  # Finds the element with the most paragraph content
  #
  # @param doc [Nokogiri::HTML::Document] Parsed HTML document
  # @return [Nokogiri::XML::Element, nil] Best content element
  def find_content_rich_element(doc)
    candidates = []

    doc.css('div, section, article').each do |element|
      paragraphs = element.css('p')
      next if paragraphs.length < 2

      # Score based on paragraph count and text density
      text_length = paragraphs.map { |p| p.text.strip.length }.sum
      link_text_length = element.css('a').map { |a| a.text.strip.length }.sum

      # Penalize elements with high link density (likely navigation)
      link_density = text_length > 0 ? link_text_length.to_f / text_length : 1.0
      next if link_density > 0.5

      score = paragraphs.length * 10 + text_length
      candidates << { element: element, score: score }
    end

    return nil if candidates.empty?

    # Return element with highest score
    candidates.max_by { |c| c[:score] }[:element]
  end

  # Cleans content element for display
  #
  # @param element [Nokogiri::XML::Element] Element to clean
  # @return [String] Cleaned HTML content
  def clean_content(element)
    # Clone to avoid modifying original
    content = element.dup

    # Remove remaining unwanted elements
    content.css('script, style, noscript, iframe, form, input, button').each(&:remove)

    # Remove empty elements
    content.css('*').each do |el|
      el.remove if el.text.strip.empty? && el.css('img, video, audio').empty?
    end

    content.inner_html
  end
end
