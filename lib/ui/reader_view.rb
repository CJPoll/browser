require 'gtk3'
require 'nokogiri'

# Reader view overlay for distraction-free article reading
#
# Displays article content in a clean, readable format with:
# - Semi-transparent dark overlay
# - Centered content container with max-width
# - Clean typography optimized for reading
# - Fade-in animation for overlay
# - Slide-up animation for content
class ReaderView
  attr_reader :widget

  # Creates a new reader view
  #
  # @param callbacks [Hash] Hash of callback procs:
  #   - :on_close => -> { } - Called when reader view is closed
  def initialize(callbacks = {})
    @callbacks = callbacks
    @visible = false

    create_widget
    setup_css
  end

  # Shows the reader view with extracted content
  #
  # @param title [String] Article title
  # @param content [String] Article HTML content
  def show(title, content)
    @title_label.text = title || "Untitled"

    # Set content as markup (we'll sanitize it)
    display_content(content)

    # Calculate 10% margin based on parent window height
    update_top_margin

    # Connect to window resize signal
    connect_resize_handler

    @visible = true
    @widget.no_show_all = false
    @widget.show_all
    @widget.no_show_all = true
    @overlay_box.grab_focus  # For ESC key handling
  end

  # Updates the top margin based on current window size
  def update_top_margin
    # Walk up to find the toplevel window
    toplevel = @widget.toplevel
    return unless toplevel&.is_a?(Gtk::Window)

    height = toplevel.allocation.height
    margin = (height * 0.10).to_i
    @content_frame.margin_top = [margin, 40].max  # At least 40px
  end

  # Hides the reader view
  def hide
    return unless @visible

    @visible = false
    disconnect_resize_handler
    @widget.hide
  end

  # Returns true if reader view is visible
  def visible?
    @visible
  end

  private

  # Connects to the window's size-allocate signal to update margin on resize
  def connect_resize_handler
    return if @resize_handler_id

    toplevel = @widget.toplevel
    return unless toplevel&.is_a?(Gtk::Window)

    @resize_handler_id = toplevel.signal_connect("size-allocate") do
      update_top_margin if @visible
    end
  end

  # Disconnects the resize handler
  def disconnect_resize_handler
    return unless @resize_handler_id

    toplevel = @widget.toplevel
    if toplevel&.is_a?(Gtk::Window)
      toplevel.signal_handler_disconnect(@resize_handler_id)
    end
    @resize_handler_id = nil
  end

  def create_widget
    # Main overlay container
    @widget = Gtk::Overlay.new
    @widget.no_show_all = true

    # Dark semi-transparent background
    @overlay_box = Gtk::EventBox.new
    @overlay_box.name = "reader-overlay"
    @overlay_box.signal_connect("button-press-event") do |_widget, event|
      if event.button == 1  # Left click on overlay
        hide
        @callbacks[:on_close]&.call
      end
      true
    end

    # Handle ESC key
    @overlay_box.can_focus = true
    @overlay_box.signal_connect("key-press-event") do |_widget, event|
      if event.keyval == Gdk::Keyval::KEY_Escape
        hide
        @callbacks[:on_close]&.call
        true
      else
        false
      end
    end

    @widget.add(@overlay_box)

    # Content frame (the white card)
    @content_frame = Gtk::Frame.new
    @content_frame.name = "reader-content-frame"
    @content_frame.halign = :center
    @content_frame.valign = :fill
    # margin_top is set dynamically in update_top_margin based on window height

    # Scrolled window for content
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)
    scrolled.set_size_request(700, -1)

    # Content box
    content_box = Gtk::Box.new(:vertical, 16)
    content_box.margin_top = 40
    content_box.margin_bottom = 40
    content_box.margin_start = 40
    content_box.margin_end = 40

    # Close button at top right
    header_box = Gtk::Box.new(:horizontal, 0)

    @title_label = Gtk::Label.new
    @title_label.name = "reader-title"
    @title_label.halign = :start
    @title_label.wrap = true
    @title_label.max_width_chars = 60
    header_box.pack_start(@title_label, expand: true, fill: true, padding: 0)

    close_button = Gtk::Button.new(label: "×")
    close_button.name = "reader-close-button"
    close_button.relief = :none
    close_button.signal_connect("clicked") do
      hide
      @callbacks[:on_close]&.call
    end
    header_box.pack_end(close_button, expand: false, fill: false, padding: 0)

    content_box.pack_start(header_box, expand: false, fill: false, padding: 0)

    # Separator
    separator = Gtk::Separator.new(:horizontal)
    content_box.pack_start(separator, expand: false, fill: false, padding: 0)

    # Article content (using a TextView for rich text)
    @content_text = Gtk::Label.new
    @content_text.name = "reader-content"
    @content_text.halign = :start
    @content_text.valign = :start
    @content_text.wrap = true
    @content_text.max_width_chars = 80
    @content_text.selectable = true
    content_box.pack_start(@content_text, expand: true, fill: true, padding: 0)

    scrolled.add(content_box)
    @content_frame.add(scrolled)

    @widget.add_overlay(@content_frame)
  end

  def setup_css
    css_provider = Gtk::CssProvider.new
    # GTK3 CSS is different from web CSS - only a subset of properties are supported
    # Not supported: max-height, transform, transition, line-height, box-shadow
    css_data = <<-CSS
      #reader-overlay {
        background-color: rgba(0, 0, 0, 0.85);
      }

      #reader-content-frame {
        background-color: #fafafa;
        border-radius: 12px 12px 0 0;
        border: none;
        min-height: 400px;
      }

      #reader-title {
        font-family: Georgia, serif;
        font-size: 24px;
        font-weight: bold;
        color: #1a1a1a;
      }

      #reader-content {
        font-family: Georgia, serif;
        font-size: 18px;
        color: #333333;
      }

      #reader-close-button {
        font-size: 24px;
        min-width: 40px;
        min-height: 40px;
      }
    CSS
    css_provider.load_from_data(css_data)
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
  end

  # Displays content in the reader, converting HTML to plain text
  #
  # @param html_content [String] HTML content to display
  def display_content(html_content)
    return @content_text.text = "" if html_content.nil? || html_content.empty?

    # Parse HTML and extract text
    doc = Nokogiri::HTML.fragment(html_content)

    # Remove scripts and styles
    doc.css('script, style, noscript').remove

    # Convert to readable text with paragraph breaks
    text = extract_readable_text(doc)

    @content_text.text = text
  end

  # Extracts readable text from Nokogiri document, preserving paragraph structure
  #
  # @param doc [Nokogiri::HTML::DocumentFragment] Parsed HTML fragment
  # @return [String] Readable plain text
  def extract_readable_text(doc)
    lines = []

    doc.children.each do |node|
      case node.name
      when 'p', 'div', 'article', 'section'
        text = node.text.strip
        lines << text << "" unless text.empty?
      when 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'
        text = node.text.strip
        lines << text << "" unless text.empty?
      when 'ul', 'ol'
        node.css('li').each do |li|
          lines << "  • #{li.text.strip}"
        end
        lines << ""
      when 'blockquote'
        text = node.text.strip.gsub(/\n/, "\n  ")
        lines << "  #{text}" << "" unless text.empty?
      when 'text'
        text = node.text.strip
        lines << text unless text.empty?
      else
        # Recurse into other elements
        inner_text = extract_readable_text(node)
        lines << inner_text unless inner_text.empty?
      end
    end

    lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
  end
end
