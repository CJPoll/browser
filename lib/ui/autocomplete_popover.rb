require 'gtk3'

# AutocompletePopover - Dropdown suggestions for URL autocomplete
#
# A GTK Popover that displays URL suggestions as the user types in the URL bar.
# Shows favicon, title, and URL for each suggestion with keyboard navigation.
#
# Features:
# - Displays up to 10 suggestions with favicon, title, and URL
# - Keyboard navigation: Up/Down to select, Enter to confirm, Escape to dismiss
# - Non-modal: user keeps typing while popover is visible
# - Automatically positioned below the URL entry
# - Selections update URL entry but don't navigate until confirmed
#
# @example Usage
#   popover = AutocompletePopover.new(url_entry, {
#     on_select: ->(uri) { navigate_to(uri) },
#     create_favicon_image: ->(data) { Gtk::Image.new(pixbuf: pixbuf) }
#   })
#   popover.update(candidates)
#   popover.show
#
class AutocompletePopover
  attr_reader :widget

  # Creates a new AutocompletePopover
  #
  # @param relative_to [Gtk::Widget] Widget to position popover relative to (URL entry)
  # @param callbacks [Hash] Callback functions:
  #   - :on_select => ->(uri) { ... } - Called when user confirms selection
  #   - :create_favicon_image => ->(data) { Gtk::Image } - Creates favicon image
  # Approximate height per row in pixels (title + URL + margins)
  ROW_HEIGHT = 50

  # Number of visible rows before scrolling
  VISIBLE_ROWS = 8

  def initialize(relative_to, callbacks)
    @callbacks = callbacks
    @relative_to = relative_to
    @candidates = []
    @selected_index = -1

    create_widget(relative_to)
  end

  # Updates the popover with new candidates
  #
  # @param candidates [Array<Hash>] Candidates with :uri, :title, :favicon, :frecency
  def update(candidates)
    @candidates = candidates
    @selected_index = -1

    populate_list
  end

  # Shows the popover
  def show
    return if @candidates.empty?

    # Select first item by default
    @selected_index = 0
    update_selection

    # Match width to URL entry
    update_popover_size

    @widget.show_all
    @widget.popup
  end

  # Hides the popover
  def hide
    @widget.popdown
  end

  # Returns true if popover is visible
  def visible?
    @widget.visible?
  end

  # Selects the next item in the list
  def select_next
    return unless visible? && !@candidates.empty?

    @selected_index = (@selected_index + 1) % @candidates.length
    update_selection
  end

  # Selects the previous item in the list
  def select_previous
    return unless visible? && !@candidates.empty?

    @selected_index = (@selected_index - 1) % @candidates.length
    update_selection
  end

  # Confirms the current selection
  #
  # @return [String, nil] Selected URI or nil if nothing selected
  def confirm_selection
    return nil unless visible? && @selected_index >= 0 && @selected_index < @candidates.length

    uri = @candidates[@selected_index][:uri]
    hide
    @callbacks[:on_select]&.call(uri)
    uri
  end

  # Returns the currently selected candidate
  #
  # @return [Hash, nil] Selected candidate or nil
  def current_selection
    return nil if @selected_index < 0 || @selected_index >= @candidates.length

    @candidates[@selected_index]
  end

  private

  def create_widget(relative_to)
    @widget = Gtk::Popover.new(relative_to)
    @widget.modal = false  # Non-modal so user can keep typing
    @widget.position = :bottom

    # Create scrolled container for list
    @scrolled = Gtk::ScrolledWindow.new
    @scrolled.hscrollbar_policy = :never
    @scrolled.vscrollbar_policy = :automatic

    # Create list box for suggestions
    @list_box = Gtk::ListBox.new
    @list_box.selection_mode = :single
    @list_box.activate_on_single_click = true

    # Handle row activation (click or Enter)
    @list_box.signal_connect("row-activated") do |_listbox, row|
      index = row.index
      if index >= 0 && index < @candidates.length
        @selected_index = index
        confirm_selection
      end
    end

    @scrolled.add(@list_box)
    @widget.add(@scrolled)
  end

  # Updates popover size to match URL entry width and show appropriate rows
  def update_popover_size
    # Get URL entry width
    entry_width = @relative_to.allocation.width
    entry_width = 400 if entry_width < 100  # Fallback minimum

    # Calculate height based on number of candidates (up to VISIBLE_ROWS)
    num_rows = [@candidates.length, VISIBLE_ROWS].min
    content_height = num_rows * ROW_HEIGHT

    # Set size request on scrolled window
    @scrolled.set_size_request(entry_width, content_height)
  end

  def populate_list
    # Clear existing rows
    @list_box.children.each { |child| @list_box.remove(child) }

    @candidates.each do |candidate|
      row = create_row(candidate)
      @list_box.add(row)
    end

    @list_box.show_all
  end

  def create_row(candidate)
    row = Gtk::ListBoxRow.new

    # Horizontal box for row content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 4
    hbox.margin_bottom = 4
    hbox.margin_start = 8
    hbox.margin_end = 8

    # Favicon
    favicon_image = create_favicon(candidate[:favicon])
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for title and URL
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title_text = candidate[:title] || candidate[:uri]
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{escape_markup(truncate(title_text, 60))}</b>"
    title_label.xalign = 0
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL (smaller, dimmed)
    url_label = Gtk::Label.new
    url_label.markup = "<small><span color='#888888'>#{escape_markup(truncate(candidate[:uri], 70))}</span></small>"
    url_label.xalign = 0
    url_label.ellipsize = :end
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    row.add(hbox)
    row
  end

  def create_favicon(favicon_data)
    if favicon_data && @callbacks[:create_favicon_image]
      begin
        return @callbacks[:create_favicon_image].call(favicon_data)
      rescue => e
        # Fall through to default
      end
    end

    # Default icon
    Gtk::Image.new(icon_name: "text-html", size: :menu)
  end

  def update_selection
    return if @selected_index < 0

    # Get all rows
    rows = @list_box.children
    return if rows.empty?

    # Clamp index to valid range
    @selected_index = [[@selected_index, 0].max, rows.length - 1].min

    # Select the row
    row = rows[@selected_index]
    @list_box.select_row(row)

    # Ensure selected row is visible
    # GTK will auto-scroll when row is selected
  end

  def truncate(text, max_length)
    return "" if text.nil?
    return text if text.length <= max_length

    text[0, max_length - 3] + "..."
  end

  def escape_markup(text)
    return "" if text.nil?

    text.gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
  end
end
