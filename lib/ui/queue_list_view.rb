require 'gtk3'
require 'cgi'
require 'uri'

# Sidebar view for displaying and managing the URL queue
class QueueListView
  attr_reader :list_widget, :queue_manager

  # Creates a new queue list view
  #
  # @param queue_manager [QueueManager] Queue manager for querying and modifying queue
  # @param favicon_image_creator [Proc] Proc that creates favicon images: ->(favicon_data) { Gtk::Image }
  def initialize(queue_manager, favicon_image_creator)
    @queue_manager = queue_manager
    @favicon_image_creator = favicon_image_creator
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Callback invoked when queue item is clicked
    # Signature: ->(entry) { ... } where entry is a hash with 'url' key
    @on_queue_item_selected = nil

    # Callback invoked after queue is modified (for refreshing count in header)
    # Signature: ->(count) { ... }
    @on_queue_modified = nil

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_queue_item_clicked(row)
    end
  end

  # Sets callback to invoke when queue item is selected
  #
  # @param callback [Proc] Callback proc accepting entry hash: ->(entry) { ... }
  # @return [void]
  def on_queue_item_selected=(callback)
    @on_queue_item_selected = callback
  end

  # Sets callback to invoke when queue is modified
  #
  # @param callback [Proc] Callback proc accepting new count: ->(count) { ... }
  # @return [void]
  def on_queue_modified=(callback)
    @on_queue_modified = callback
  end

  # Refreshes the queue list display
  #
  # @param current_url [String, nil] Current tab's URL for highlighting (nil if no current tab)
  # @return [void]
  def refresh(current_url = nil)
    # Clear existing items
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Get all queue entries
    entries = @queue_manager.all

    entries.each do |entry|
      row = create_queue_row(entry)
      @list_widget.add(row)

      # Highlight the queue entry that matches the current tab's URL
      # Use fuzzy matching: queue URL params must be subset of current URL params
      if current_url && entry['url'] && urls_match?(entry['url'], current_url)
        @list_widget.select_row(row)
      end
    end

    @list_widget.show_all

    # Notify callback of new count
    @on_queue_modified.call(entries.length) if @on_queue_modified
  end

  private

  # Creates a list box row for a queue entry
  #
  # @param entry [Hash] Entry data with keys: 'id', 'url', 'title', 'favicon', 'position'
  # @return [Gtk::ListBoxRow] Configured row widget
  def create_queue_row(entry)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content + actions
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = @favicon_image_creator.call(entry['favicon'])
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = entry['title'] || entry['url']
    # Ensure UTF-8 encoding for display
    title = title.dup.force_encoding('UTF-8') if title
    unless title.valid_encoding?
      title = title.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..60])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(entry['url'])
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Position indicator
    position_label = Gtk::Label.new("##{entry['position']}")
    position_label.halign = :start
    position_label.style_context.add_class("dim-label")
    vbox.pack_start(position_label, expand: false, fill: false, padding: 0)

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    # Remove button
    remove_button = Gtk::Button.new(label: "×")
    remove_button.relief = :none
    remove_button.signal_connect("clicked") do
      @queue_manager.remove_by_id(entry['id'])
      refresh()  # Refresh after removal
      true  # Stop event propagation to prevent row-activated signal
    end
    hbox.pack_start(remove_button, expand: false, fill: false, padding: 0)

    # Wrap in EventBox to enable mouse events for drag-and-drop
    event_box = Gtk::EventBox.new
    event_box.add(hbox)
    event_box.visible_window = false  # Transparent event box (no background)

    row.add(event_box)

    # Store entry data in the row and event_box
    row.instance_variable_set(:@queue_entry, entry)
    event_box.instance_variable_set(:@queue_entry, entry)
    event_box.instance_variable_set(:@parent_row, row)

    # Set up drag-and-drop for reordering on the event_box
    setup_queue_row_drag_and_drop(event_box)

    row
  end

  # Sets up drag-and-drop reordering for a queue row
  #
  # @param widget [Gtk::EventBox] Event box wrapping the row content
  # @return [void]
  def setup_queue_row_drag_and_drop(widget)
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
    # Use MOTION and HIGHLIGHT but NOT DROP - we handle drop manually to avoid conflicts
    # Including DROP would cause GTK to auto-finish drag before our handler runs
    widget.drag_dest_set(
      Gtk::DestDefaults::MOTION | Gtk::DestDefaults::HIGHLIGHT,
      [target_entry],
      Gdk::DragAction::MOVE
    )

    # Store reference to view for callbacks
    view = self

    # Handle drag data get (provide the data when dragging)
    widget.signal_connect("drag-data-get") do |w, context, selection_data, info, time|
      entry = w.instance_variable_get(:@queue_entry)
      if entry
        # Send the entry ID as plain text (converted to string for transfer)
        selection_data.text = entry['id'].to_s
      end
    end

    # Handle drag drop
    widget.signal_connect("drag-drop") do |w, context, x, y, time|
      # Request the drag data - this will trigger drag-data-received
      target = Gdk::Atom.intern("TEXT", false)
      w.drag_get_data(context, target, time)
      true
    end

    # Handle drag data received (handle the drop)
    widget.signal_connect("drag-data-received") do |w, context, x, y, selection_data, info, time|
      # Get the dropped entry ID
      dropped_id_text = selection_data.text

      if dropped_id_text && !dropped_id_text.empty?
        dropped_entry_id = dropped_id_text.to_i  # Convert back to integer
        target_entry = w.instance_variable_get(:@queue_entry)

        if target_entry && dropped_entry_id != target_entry['id']
          # Move the dropped entry to the target position
          if view.queue_manager.move(dropped_entry_id, target_entry['position'])
            # Refresh the queue to show the new order
            view.refresh()

            # Find and select the moved row
            view.list_widget.children.each do |child|
              child_entry = child.instance_variable_get(:@queue_entry)
              if child_entry && child_entry['id'] == dropped_entry_id
                view.list_widget.select_row(child)
                break
              end
            end
          end
        end
      end

      # Finish the drag operation
      context.finish(true, false, time)
    end
  end

  # Handles queue item click
  #
  # @param row [Gtk::ListBoxRow] Clicked row
  # @return [void]
  def on_queue_item_clicked(row)
    entry = row.instance_variable_get(:@queue_entry)
    @on_queue_item_selected.call(entry) if @on_queue_item_selected && entry
  end

  # Compares two URLs with bidirectional subset parameter matching
  #
  # @param queue_url [String] URL from queue entry
  # @param current_url [String] Current tab's URL
  # @return [Boolean] True if URLs match (same base + compatible params)
  def urls_match?(queue_url, current_url)
    # Parse both URLs
    begin
      queue_uri = URI.parse(queue_url)
      current_uri = URI.parse(current_url)
    rescue URI::InvalidURIError
      return false
    end

    # Compare base URLs (scheme, host, path) - ignore trailing slashes
    queue_base = "#{queue_uri.scheme}://#{queue_uri.host}#{queue_uri.path}".sub(/\/$/, '')
    current_base = "#{current_uri.scheme}://#{current_uri.host}#{current_uri.path}".sub(/\/$/, '')
    return false unless queue_base == current_base

    # Parse query parameters
    queue_params = queue_uri.query ? CGI.parse(queue_uri.query) : {}
    current_params = current_uri.query ? CGI.parse(current_uri.query) : {}

    # Check if either URL's params are a subset of the other
    # This handles both cases:
    # 1. Queue has extra params (YouTube strips them) - current is subset of queue
    # 2. Current has extra params - queue is subset of current
    params_are_subset?(queue_params, current_params) || params_are_subset?(current_params, queue_params)
  end

  # Checks if subset params are all present in superset params
  #
  # @param subset_params [Hash] Parameters that should all be in superset
  # @param superset_params [Hash] Parameters that should contain all of subset
  # @return [Boolean] True if all subset params exist in superset with same values
  def params_are_subset?(subset_params, superset_params)
    # Check if all params in subset exist in superset with same values
    subset_params.all? do |key, values|
      superset_params[key] == values
    end
  end
end
