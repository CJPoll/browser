require 'gtk3'
require 'cgi'

# Sidebar view for displaying browser tabs
class TabListView
  attr_reader :list_widget

  # Creates a new tab list view
  #
  # @param favicon_image_creator [Proc] Proc that creates favicon images: ->(favicon_data) { Gtk::Image }
  def initialize(favicon_image_creator)
    @favicon_image_creator = favicon_image_creator
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Callback invoked when tab is clicked
    # Signature: ->(tab_index) { ... }
    @on_tab_selected = nil

    # Callback invoked when tab is reordered via drag-and-drop
    # Signature: ->(from_index, to_index) { ... }
    @on_tab_reordered = nil

    # Callback invoked when tab close button is clicked
    # Signature: ->(tab_index) { ... }
    @on_tab_closed = nil

    # Track the current drop indicator row
    @drop_indicator_row = nil

    # Set up CSS for drop indicator
    setup_drop_indicator_css

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_tab_clicked(row)
    end
  end

  # Sets callback to invoke when tab is selected
  #
  # @param callback [Proc] Callback proc accepting tab index: ->(index) { ... }
  # @return [void]
  def on_tab_selected=(callback)
    @on_tab_selected = callback
  end

  # Sets callback to invoke when tab is reordered
  #
  # @param callback [Proc] Callback proc accepting from and to indices: ->(from_index, to_index) { ... }
  # @return [void]
  def on_tab_reordered=(callback)
    @on_tab_reordered = callback
  end

  # Reports that the user dragged one tab onto another's place
  #
  # @param from_index [Integer] Where the tab was
  # @param to_index [Integer] Where the user dropped it
  # @return [void]
  def reorder_tab(from_index, to_index)
    @on_tab_reordered&.call(from_index, to_index)
  end

  # Sets callback to invoke when tab close button is clicked
  #
  # @param callback [Proc] Callback proc accepting tab index: ->(index) { ... }
  # @return [void]
  def on_tab_closed=(callback)
    @on_tab_closed = callback
  end

  # Refreshes the tab list display
  #
  # @param tabs [Array<Tab>] Array of Tab objects
  # @param current_tab_index [Integer] Index of currently active tab
  # @return [void]
  def refresh(tabs, current_tab_index)
    # Clear existing items
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Add a row for each tab
    tabs.each_with_index do |tab, index|
      row = create_tab_row(tab, index)
      @list_widget.add(row)

      # Highlight the current tab
      if index == current_tab_index
        @list_widget.select_row(row)
      end
    end

    @list_widget.show_all
  end

  # Updates the drop indicator position
  #
  # @param row [Gtk::ListBoxRow] The row being hovered over
  # @param y [Integer] Y coordinate within the row
  def update_drop_indicator(row, y)
    return unless row

    # Clear previous indicator
    clear_drop_indicator

    # Determine if we're in the top or bottom half of the row
    row_height = row.allocation.height
    above = y < (row_height / 2)

    # Add the appropriate CSS class
    if above
      row.style_context.add_class("drop-indicator-above")
    else
      row.style_context.add_class("drop-indicator-below")
    end

    @drop_indicator_row = row
  end

  # Clears the drop indicator from any row
  def clear_drop_indicator
    if @drop_indicator_row
      @drop_indicator_row.style_context.remove_class("drop-indicator-above")
      @drop_indicator_row.style_context.remove_class("drop-indicator-below")
      @drop_indicator_row = nil
    end
  end

  private

  # Sets up CSS for the drop indicator styling
  def setup_drop_indicator_css
    css_provider = Gtk::CssProvider.new
    css_data = <<-CSS
      .drop-indicator-above {
        border-top: 3px solid @theme_selected_bg_color;
      }
      .drop-indicator-below {
        border-bottom: 3px solid @theme_selected_bg_color;
      }
    CSS
    css_provider.load_from_data(css_data)
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
  end

  # Creates a list box row for a tab
  #
  # @param tab [Tab] Tab object
  # @param index [Integer] Tab index in tabs array
  # @return [Gtk::ListBoxRow] Configured row widget
  def create_tab_row(tab, index)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = @favicon_image_creator.call(tab.favicon_data)
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = tab.title || "New Tab"
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..40])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    if tab.uri && !tab.uri.empty?
      url_label = Gtk::Label.new(tab.uri)
      url_label.halign = :start
      url_label.ellipsize = :middle
      url_label.max_width_chars = 30
      url_label.style_context.add_class("dim-label")
      vbox.pack_start(url_label, expand: false, fill: false, padding: 0)
    end

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    # Close button
    close_button = Gtk::Button.new(label: "×")
    close_button.relief = :none
    close_button.signal_connect("clicked") do
      @on_tab_closed&.call(index)
      true  # Stop event propagation to prevent row-activated signal
    end
    hbox.pack_start(close_button, expand: false, fill: false, padding: 0)

    # Wrap in EventBox to enable mouse events for drag-and-drop
    event_box = Gtk::EventBox.new
    event_box.add(hbox)
    event_box.visible_window = false  # Transparent event box (no background)

    row.add(event_box)

    # Store the tab index in the row and event_box
    row.instance_variable_set(:@tab_index, index)
    event_box.instance_variable_set(:@tab_index, index)
    event_box.instance_variable_set(:@parent_row, row)

    # Set up drag-and-drop for reordering on the event_box
    setup_tab_row_drag_and_drop(event_box)

    row
  end

  # Sets up drag-and-drop reordering for a tab row
  #
  # @param widget [Gtk::EventBox] Event box wrapping the row content
  # @return [void]
  def setup_tab_row_drag_and_drop(widget)
    # Create target entry for drag-and-drop using standard text target
    # "TEXT" is a recognized text type that works with set_text/get_text
    target_entry = Gtk::TargetEntry.new("TEXT", :same_app, 0)

    # Set up as drag source
    widget.drag_source_set(
      Gdk::ModifierType::BUTTON1_MASK,
      [target_entry],
      Gdk::DragAction::MOVE
    )

    # Set up as drag destination
    # Use MOTION but NOT DROP or HIGHLIGHT - we handle these manually
    widget.drag_dest_set(
      Gtk::DestDefaults::MOTION,
      [target_entry],
      Gdk::DragAction::MOVE
    )

    # Store reference to view for callbacks
    view = self

    # Handle drag data get (provide the data when dragging)
    widget.signal_connect("drag-data-get") do |w, context, selection_data, info, time|
      tab_index = w.instance_variable_get(:@tab_index)
      if tab_index
        # Send the tab index as plain text
        selection_data.text = tab_index.to_s
      end
    end

    # Handle drag motion (show drop indicator)
    widget.signal_connect("drag-motion") do |w, context, x, y, time|
      parent_row = w.instance_variable_get(:@parent_row)
      view.update_drop_indicator(parent_row, y)
      Gdk.drag_status(context, :move, time)
      true
    end

    # Handle drag leave (clear indicator when leaving widget)
    widget.signal_connect("drag-leave") do |w, context, time|
      # Don't clear immediately - let drag-motion on next widget handle it
      # This prevents flicker when moving between rows
    end

    # Handle drag drop
    widget.signal_connect("drag-drop") do |w, context, x, y, time|
      # Clear the drop indicator
      view.clear_drop_indicator

      # Request the drag data - this will trigger drag-data-received
      target = Gdk::Atom.intern("TEXT", false)
      w.drag_get_data(context, target, time)
      true
    end

    # Handle drag data received (handle the drop)
    widget.signal_connect("drag-data-received") do |w, context, x, y, selection_data, info, time|
      # Get the dropped tab index
      dropped_index_text = selection_data.text

      if dropped_index_text && !dropped_index_text.empty?
        from_index = dropped_index_text.to_i
        to_index = w.instance_variable_get(:@tab_index)

        view.reorder_tab(from_index, to_index) if to_index && from_index != to_index
      end

      # Finish the drag operation
      context.finish(true, false, time)
    end

    # Handle drag end (clear indicator if drag cancelled)
    widget.signal_connect("drag-end") do |w, context|
      view.clear_drop_indicator
    end
  end

  # Handles tab row click
  #
  # @param row [Gtk::ListBoxRow] Clicked row
  # @return [void]
  def on_tab_clicked(row)
    tab_index = row.instance_variable_get(:@tab_index)
    @on_tab_selected.call(tab_index) if @on_tab_selected && tab_index
  end
end
