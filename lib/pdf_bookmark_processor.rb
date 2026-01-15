require 'hexapdf'

# Adds PDF bookmarks/outline to PDFs based on heading structure
#
# Thread Safety: File I/O operations, not thread-safe
class PdfBookmarkProcessor
  # Represents a heading with its text, level, and page number
  Heading = Struct.new(:text, :level, :page, keyword_init: true)

  # Adds bookmarks to a PDF file based on markdown headings
  #
  # @param pdf_path [String] Path to the PDF file to modify
  # @param markdown_content [String] The markdown source content
  # @return [Boolean] true if bookmarks were added successfully
  def self.add_bookmarks(pdf_path, markdown_content)
    puts "[PdfBookmarkProcessor] Starting add_bookmarks"
    puts "[PdfBookmarkProcessor] PDF path: #{pdf_path}"

    unless File.exist?(pdf_path)
      puts "[PdfBookmarkProcessor] ✗ PDF file does not exist"
      return false
    end

    unless markdown_content
      puts "[PdfBookmarkProcessor] ✗ No markdown content provided"
      return false
    end

    # Extract headings from markdown
    puts "[PdfBookmarkProcessor] Extracting headings from markdown..."
    headings = extract_headings(markdown_content)
    puts "[PdfBookmarkProcessor] Found #{headings.size} headings"

    if headings.empty?
      puts "[PdfBookmarkProcessor] ✗ No headings found in markdown"
      return false
    end

    headings.each_with_index do |h, i|
      puts "[PdfBookmarkProcessor]   #{i+1}. [h#{h.level}] #{h.text}"
    end

    # Open PDF and find page numbers for each heading
    puts "[PdfBookmarkProcessor] Opening PDF document..."
    doc = HexaPDF::Document.open(pdf_path)
    puts "[PdfBookmarkProcessor] PDF has #{doc.pages.count} pages"

    puts "[PdfBookmarkProcessor] Finding page numbers for each heading..."
    headings_with_pages = find_heading_pages(doc, headings)
    puts "[PdfBookmarkProcessor] Mapped #{headings_with_pages.size}/#{headings.size} headings to pages"

    headings_with_pages.each do |h|
      puts "[PdfBookmarkProcessor]   [h#{h.level}] #{h.text} → page #{h.page + 1}"
    end

    # Build bookmark outline
    puts "[PdfBookmarkProcessor] Building PDF outline..."
    build_outline(doc, headings_with_pages)

    # Save the modified PDF
    puts "[PdfBookmarkProcessor] Saving modified PDF..."
    doc.write(pdf_path, optimize: true)
    puts "[PdfBookmarkProcessor] ✓ Successfully added bookmarks to PDF"
    true
  rescue => e
    puts "[PdfBookmarkProcessor] ✗ Error: #{e.message}"
    puts "[PdfBookmarkProcessor] Backtrace:"
    puts e.backtrace.first(5).map { |line| "  #{line}" }
    false
  end

  private

  # Extracts headings from markdown content
  #
  # @param content [String] Markdown content
  # @return [Array<Heading>] Array of headings without page numbers
  def self.extract_headings(content)
    headings = []
    content.each_line do |line|
      # Match markdown headings: # H1, ## H2, etc.
      if line =~ /^([#]{1,6})\s+(.+?)$/
        level = $1.length
        text = $2.strip
        headings << Heading.new(text: text, level: level, page: nil)
      end
    end
    headings
  end

  # Finds the page number for each heading by searching PDF content
  #
  # @param doc [HexaPDF::Document] The PDF document
  # @param headings [Array<Heading>] Headings to find
  # @return [Array<Heading>] Headings with page numbers filled in
  def self.find_heading_pages(doc, headings)
    headings_with_pages = []

    headings.each do |heading|
      page_index = find_text_in_pdf(doc, heading.text)
      if page_index
        headings_with_pages << Heading.new(
          text: heading.text,
          level: heading.level,
          page: page_index
        )
      end
    end

    headings_with_pages
  end

  # Searches PDF for text and returns the first page index where found
  #
  # @param doc [HexaPDF::Document] The PDF document
  # @param text [String] Text to search for
  # @return [Integer, nil] Zero-based page index, or nil if not found
  def self.find_text_in_pdf(doc, text)
    doc.pages.each_with_index do |page, index|
      begin
        # Extract text using a content processor
        processor = TextExtractorProcessor.new
        page.process_contents(processor)
        page_text = processor.text

        if page_text.include?(text)
          puts "[PdfBookmarkProcessor]     Found '#{text.slice(0, 50)}...' on page #{index + 1}"
          return index
        end
      rescue => e
        puts "[PdfBookmarkProcessor]     ⚠ Error extracting text from page #{index + 1}: #{e.class.name}: #{e.message}"
        # Continue to next page - don't let one bad page break everything
        next
      end
    end
    nil
  end

  # Simple text extractor processor for HexaPDF
  class TextExtractorProcessor < HexaPDF::Content::Processor
    attr_reader :text

    def initialize
      super
      @text = ''
    end

    def show_text(str)
      @text << decode_text(str)
    end

    def show_text_with_positioning(array)
      array.each do |item|
        show_text(item) if item.is_a?(String)
      end
    end
  end

  # Builds the PDF outline/bookmark structure
  #
  # @param doc [HexaPDF::Document] The PDF document
  # @param headings [Array<Heading>] Headings with page numbers
  def self.build_outline(doc, headings)
    return if headings.empty?

    puts "[PdfBookmarkProcessor] Building outline tree..."

    # Get or create outline
    outline = doc.outline

    # Stack to track parent items for each level
    # level_stack[0] = h1 parent, level_stack[1] = h2 parent, etc.
    level_stack = []

    headings.each_with_index do |heading, idx|
      # Pop stack until we find the appropriate parent level
      while level_stack.size >= heading.level
        level_stack.pop
      end

      # Create the outline item
      puts "[PdfBookmarkProcessor]   Adding bookmark #{idx+1}/#{headings.size}: [h#{heading.level}] #{heading.text}"

      if level_stack.empty?
        # This is a top-level item - add directly to outline
        item = outline.add_item(heading.text, destination: heading.page)
      else
        # This is a nested item - add as child of parent
        parent = level_stack.last
        item = parent.add_item(heading.text, destination: heading.page)
        puts "[PdfBookmarkProcessor]     (nested under previous h#{heading.level - 1})"
      end

      # Add this item to the stack as potential parent for next items
      level_stack[heading.level - 1] = item
    end

    puts "[PdfBookmarkProcessor] Outline tree complete with #{headings.size} bookmarks"
  end
end
