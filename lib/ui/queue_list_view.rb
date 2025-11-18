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
    # Signature: ->(filtered_count, total_count) { ... }
    @on_queue_modified = nil

    # Callback invoked when tag pill is clicked
    # Signature: ->(tag_name) { ... }
    @on_tag_pill_clicked = nil

    # Callback invoked when queue entry is right-clicked
    # Signature: ->(entry, event) { ... }
    @on_queue_entry_right_click = nil

    # Filter state
    @active_filter_tag_ids = []  # Array of tag IDs (AND logic)

    # Sort state
    @current_sort_mode = :position  # :position, :title, :date_published

    # Callback to get current tab URL (for highlighting after filter)
    # Signature: -> { String or nil }
    @on_get_current_url = nil

    # Callback when filter state changes (for sidebar button state)
    # Signature: ->(active) { ... } where active is boolean
    @on_filter_state_changed = nil

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

  # Sets callback to invoke when tag pill is clicked
  #
  # @param callback [Proc] Callback proc accepting tag name: ->(tag_name) { ... }
  # @return [void]
  def on_tag_pill_clicked=(callback)
    @on_tag_pill_clicked = callback
  end

  # Sets callback to invoke when queue entry is right-clicked
  #
  # @param callback [Proc] Callback proc accepting entry and event: ->(entry, event) { ... }
  # @return [void]
  def on_queue_entry_right_click=(callback)
    @on_queue_entry_right_click = callback
  end

  # Sets callback to get current URL
  #
  # @param callback [Proc] Callback returning URL string or nil
  # @return [void]
  def on_get_current_url=(callback)
    @on_get_current_url = callback
  end

  # Sets callback when filter state changes
  #
  # @param callback [Proc] Callback accepting boolean (filters active)
  # @return [void]
  def on_filter_state_changed=(callback)
    @on_filter_state_changed = callback
  end

  # Generates RGB color for a tag name (deterministic, case-insensitive)
  # PUBLIC for testing
  # @param tag_name [String] Tag name to generate color for
  # @return [Array<Integer>] RGB values as [r, g, b] (0-255 range)
  def tag_color_rgb(tag_name)
    # Generate hue from tag name (0-360 degrees)
    hash = tag_name.downcase.sum % 360
    hue = hash
    saturation = 70  # 70% - vibrant colors
    lightness = 60   # 60% - readable against white background

    hsl_to_rgb(hue, saturation, lightness)
  end

  # Adds a tag to the active filters
  #
  # @param tag_id [Integer] Tag ID to add
  # @return [void]
  def add_filter_tag(tag_id)
    return if @active_filter_tag_ids.include?(tag_id)

    @active_filter_tag_ids << tag_id
    apply_filters
  end

  # Removes a tag from active filters
  #
  # @param tag_id [Integer] Tag ID to remove
  # @return [void]
  def remove_filter_tag(tag_id)
    @active_filter_tag_ids.delete(tag_id)
    apply_filters
  end

  # Clears all active filters
  #
  # @return [void]
  def clear_all_filters
    @active_filter_tag_ids = []
    apply_filters
  end

  # Adds filter for tag by name (used by tag pill click)
  #
  # @param tag_name [String] Tag name to filter by
  # @return [void]
  def filter_by_tag_name(tag_name)
    tag = @queue_manager.find_tag_by_name(tag_name)
    return unless tag

    # Set as the only active filter (replaces existing filters)
    @active_filter_tag_ids = [tag['id']]
    apply_filters
  end

  # Returns whether any filters are active
  #
  # @return [Boolean] True if filters are active
  def filters_active?
    @active_filter_tag_ids.any?
  end

  # Returns array of active filter tag names (for display)
  #
  # @return [Array<String>] Tag names
  def active_filter_tag_names
    @active_filter_tag_ids.map do |tag_id|
      tag = @queue_manager.find_tag_by_id(tag_id)
      tag ? tag['name'] : nil
    end.compact
  end

  # Removes a deleted tag from active filters
  # Call this when a tag is deleted from the system
  #
  # @param tag_id [Integer] ID of the deleted tag
  # @return [void]
  def remove_deleted_tag_from_filters(tag_id)
    return unless @active_filter_tag_ids.include?(tag_id)

    @active_filter_tag_ids.delete(tag_id)
    apply_filters
  end

  # Sets the current sort mode
  #
  # @param mode [Symbol] One of :position, :title, :date_published
  # @return [void]
  def set_sort_mode(mode)
    return if @current_sort_mode == mode

    @current_sort_mode = mode

    # Get current URL for highlighting
    current_url = @on_get_current_url&.call

    # Refresh with new sort
    refresh(current_url)
  end

  # Returns current sort mode
  #
  # @return [Symbol] Current sort mode
  def current_sort_mode
    @current_sort_mode
  end

  # Shows filter popover attached to the given widget
  #
  # @param relative_to [Gtk::Widget] Widget to position popover relative to
  # @return [void]
  def show_filter_popover(relative_to)
    @filter_popover = create_filter_popover(relative_to)
    @filter_popover.show_all

    # Hide clear button if no filters active
    @clear_filters_button.visible = @active_filter_tag_ids.any?

    @filter_popover.popup
  end

  # Refreshes the queue list display
  #
  # @param current_url [String, nil] Current tab's URL for highlighting (nil if no current tab)
  # @return [void]
  def refresh(current_url = nil)
    # Clear existing items
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Get filtered and sorted entries
    entries = get_filtered_sorted_entries
    total_count = @queue_manager.count

    # Check for empty state
    if entries.empty? && @active_filter_tag_ids.any?
      # Show empty state for "no matches"
      show_empty_filter_state
    else
      # Render entries
      entries.each do |entry|
        row = create_queue_row(entry)
        @list_widget.add(row)

        # Highlight the queue entry that matches the current tab's URL
        if current_url && entry['url'] && urls_match?(entry['url'], current_url)
          @list_widget.select_row(row)
        end
      end
    end

    @list_widget.show_all

    # Notify callback with filtered count and total count
    @on_queue_modified.call(entries.length, total_count) if @on_queue_modified
  end

  private

  # Gets queue entries with current filters and sort applied
  #
  # @return [Array<Hash>] Filtered and sorted entries
  def get_filtered_sorted_entries
    if @active_filter_tag_ids.empty?
      # No filters - get all entries
      entries = @queue_manager.all
    else
      # Apply AND filter
      entries = @queue_manager.entries_with_tags(@active_filter_tag_ids)
    end

    # Apply sorting
    case @current_sort_mode
    when :position
      # Already sorted by position from database
      entries
    when :title
      entries.sort_by { |e| (e['title'] || e['url']).downcase }
    when :date_published
      # Sort by date descending, NULLs last
      entries.sort do |a, b|
        date_a = a['date']
        date_b = b['date']

        if date_a.nil? && date_b.nil?
          0
        elsif date_a.nil?
          1  # NULLs go to end
        elsif date_b.nil?
          -1  # NULLs go to end
        else
          date_b <=> date_a  # Descending (newest first)
        end
      end
    else
      entries
    end
  end

  # Applies current filters and refreshes display
  def apply_filters
    # Get current URL for highlighting
    # Note: This requires callback to get current tab URL
    current_url = @on_get_current_url&.call

    # Refresh the display with current filters
    refresh(current_url)

    # Notify sidebar of filter state change
    @on_filter_state_changed&.call(filters_active?)

    # Update clear button visibility in popover if open
    # Note: Use safe navigation since popover may be closed/destroyed
    @clear_filters_button&.visible = filters_active?
  end

  # Shows empty state when filters match no entries
  def show_empty_filter_state
    # Create empty state container
    empty_box = Gtk::Box.new(:vertical, 8)
    empty_box.valign = :center
    empty_box.halign = :center
    empty_box.margin_top = 40
    empty_box.margin_bottom = 40

    # Message label
    message_label = Gtk::Label.new("No entries match the selected filters.")
    message_label.style_context.add_class("dim-label")
    empty_box.pack_start(message_label, expand: false, fill: false, padding: 0)

    # Clear filters button
    clear_button = Gtk::Button.new(label: "Clear Filters")
    clear_button.halign = :center
    clear_button.signal_connect("clicked") do
      clear_all_filters
    end
    empty_box.pack_start(clear_button, expand: false, fill: false, padding: 8)

    # Wrap in ListBoxRow for consistency
    row = Gtk::ListBoxRow.new
    row.activatable = false
    row.selectable = false
    row.add(empty_box)

    @list_widget.add(row)
  end

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

    # Tags display
    tags = @queue_manager.tags_for_entry(entry['id'])
    tags_box = Gtk::Box.new(:horizontal, 8)
    tags_box.halign = :start

    if tags.length > 0
      # Sort tags alphabetically (case-insensitive)
      sorted_tags = tags.sort_by { |tag| tag['name'].downcase }

      # Show first 3 tags
      visible_tags = sorted_tags.take(3)
      visible_tags.each do |tag|
        pill = create_tag_pill(tag['name'])
        tags_box.pack_start(pill, expand: false, fill: false, padding: 0)
      end

      # Show "+N more" if needed
      if sorted_tags.length > 3
        remaining_count = sorted_tags.length - 3
        more_label = Gtk::Label.new("+#{remaining_count} more")
        more_label.style_context.add_class("dim-label")
        tags_box.pack_start(more_label, expand: false, fill: false, padding: 0)
      end
    end

    vbox.pack_start(tags_box, expand: false, fill: false, padding: 0)

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

    # Set up right-click context menu handler
    event_box.signal_connect("button-press-event") do |widget, event|
      if event.button == 3  # Right click
        entry = widget.instance_variable_get(:@queue_entry)
        @on_queue_entry_right_click.call(entry, event) if @on_queue_entry_right_click
        true  # Stop propagation
      else
        false  # Allow other handlers
      end
    end

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

  private

  # Converts HSL color to RGB values (0-255 range)
  # @param hue [Integer] Hue in degrees (0-360)
  # @param saturation [Integer] Saturation percentage (0-100)
  # @param lightness [Integer] Lightness percentage (0-100)
  # @return [Array<Integer>] RGB values as [r, g, b] (0-255 range)
  def hsl_to_rgb(hue, saturation, lightness)
    # Convert HSL to RGB
    # Formula from https://en.wikipedia.org/wiki/HSL_and_HSV#HSL_to_RGB
    c = (1 - (2 * lightness / 100.0 - 1).abs) * (saturation / 100.0)
    h_prime = hue / 60.0
    x = c * (1 - (h_prime % 2 - 1).abs)

    r1, g1, b1 = case h_prime.floor
      when 0 then [c, x, 0]
      when 1 then [x, c, 0]
      when 2 then [0, c, x]
      when 3 then [0, x, c]
      when 4 then [x, 0, c]
      when 5 then [c, 0, x]
      else [0, 0, 0]
    end

    m = lightness / 100.0 - c / 2.0
    r = ((r1 + m) * 255).round
    g = ((g1 + m) * 255).round
    b = ((b1 + m) * 255).round

    [r, g, b]
  end

  # Create Gdk::RGBA from tag name
  # @param tag_name [String] Tag name to generate color for
  # @return [Gdk::RGBA] RGBA color object for GTK
  def tag_color_rgba(tag_name)
    r, g, b = tag_color_rgb(tag_name)
    Gdk::RGBA.new(r / 255.0, g / 255.0, b / 255.0, 1.0)
  end

  # Creates a tag pill widget for display in queue row
  # @param tag_name [String] Tag name to display
  # @return [Gtk::EventBox] EventBox containing tag pill
  def create_tag_pill(tag_name)
    # EventBox for click handling
    event_box = Gtk::EventBox.new

    # Label with tag name
    label = Gtk::Label.new(tag_name)
    label.override_color(:normal, Gdk::RGBA.new(1.0, 1.0, 1.0, 1.0))  # White text
    label.margin_top = 4
    label.margin_bottom = 4
    label.margin_start = 6
    label.margin_end = 6

    # Override background color
    rgba = tag_color_rgba(tag_name)
    event_box.override_background_color(:normal, rgba)

    # Add padding and border radius via CSS
    # Note: GTK retains CSS providers added to StyleContext.
    # When EventBox is destroyed, StyleContext is also destroyed,
    # automatically releasing the provider reference.
    # No explicit cleanup needed.
    css_provider = Gtk::CssProvider.new
    css_data = <<-CSS
      * {
        padding: 4px 6px;
        border-radius: 3px;
        font-size: 90%;
      }
    CSS
    css_provider.load_from_data(css_data)
    event_box.style_context.add_provider(
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )

    event_box.add(label)

    # Accessibility:
    # Phase 4: "Filter by #{tag_name}" indicates clicking will apply filter
    event_box.accessible.accessible_name = "Filter by #{tag_name}"

    # Click handler
    # UX Decision: Clicking tag pill should ONLY trigger tag filtering (no navigation)
    # Return TRUE to stop propagation - prevents row-activated signal
    # User can click elsewhere on row to navigate, or click pill to filter
    event_box.signal_connect("button-press-event") do |widget, event|
      if event.button == 1  # Left click
        on_tag_pill_clicked(tag_name)
        # Return TRUE to stop propagation - pill click is independent action
        # Does NOT navigate to URL (user must click on title/URL area for that)
        true
      else
        false  # Allow other handlers (right-click, etc.)
      end
    end

    # Store tag name for reference
    event_box.instance_variable_set(:@tag_name, tag_name)

    event_box
  end

  # Callback invoked when tag pill is clicked
  # Filters queue to show only entries with this tag
  # PRIVATE method
  def on_tag_pill_clicked(tag_name)
    # Phase 4: Filter by this tag (replaces Phase 2 console logging)
    filter_by_tag_name(tag_name)

    # Invoke external callback if set (for any additional handling)
    @on_tag_pill_clicked.call(tag_name) if @on_tag_pill_clicked
  end

  # Creates filter popover widget
  #
  # @param relative_to [Gtk::Widget] Widget to position popover relative to
  # @return [Gtk::Popover] Configured popover
  def create_filter_popover(relative_to)
    popover = Gtk::Popover.new(relative_to)
    popover.position = :bottom

    # Main container
    vbox = Gtk::Box.new(:vertical, 8)
    vbox.margin_top = 12
    vbox.margin_bottom = 12
    vbox.margin_start = 12
    vbox.margin_end = 12

    # Title
    title_label = Gtk::Label.new
    title_label.markup = "<b>Filter by Tags</b>"
    title_label.halign = :start
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # Separator
    separator1 = Gtk::Separator.new(:horizontal)
    vbox.pack_start(separator1, expand: false, fill: false, padding: 4)

    # Scrolled window for tag checkboxes (in case of many tags)
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)
    scrolled.set_size_request(250, 600)  # Fixed width, min height for ~8 tags
    scrolled.max_content_height = 300   # Max height before scrolling

    # Tag checkboxes container
    tags_box = Gtk::Box.new(:vertical, 4)

    # Get tag usage counts
    tag_counts = @queue_manager.tag_usage_counts

    if tag_counts.empty?
      # No tags exist - show message
      no_tags_label = Gtk::Label.new("No tags available")
      no_tags_label.style_context.add_class("dim-label")
      tags_box.pack_start(no_tags_label, expand: false, fill: false, padding: 8)
    else
      # Create checkbox for each tag with usage count
      tag_counts.each do |tag_data|
        checkbox = create_filter_checkbox(tag_data)
        tags_box.pack_start(checkbox, expand: false, fill: false, padding: 0)
      end
    end

    scrolled.add(tags_box)
    vbox.pack_start(scrolled, expand: true, fill: true, padding: 0)

    # Separator before clear button
    separator2 = Gtk::Separator.new(:horizontal)
    vbox.pack_start(separator2, expand: false, fill: false, padding: 4)

    # Clear filters button
    @clear_filters_button = Gtk::Button.new(label: "Clear Filters")
    @clear_filters_button.halign = :start
    @clear_filters_button.signal_connect("clicked") do
      clear_all_filters
      @filter_popover.popdown
    end
    vbox.pack_start(@clear_filters_button, expand: false, fill: false, padding: 0)

    popover.add(vbox)
    popover
  end

  # Creates a filter checkbox for a tag
  #
  # @param tag_data [Hash] Hash with 'tag_id', 'tag_name', 'count' keys
  # @return [Gtk::CheckButton] Configured checkbox
  def create_filter_checkbox(tag_data)
    tag_id = tag_data['tag_id']
    tag_name = tag_data['tag_name']
    count = tag_data['count']

    checkbox = Gtk::CheckButton.new
    checkbox.label = "#{tag_name} (#{count})"

    # Check if tag is currently in filter
    checkbox.active = @active_filter_tag_ids.include?(tag_id)

    # Handle toggle
    checkbox.signal_connect("toggled") do
      if checkbox.active?
        add_filter_tag(tag_id)
      else
        remove_filter_tag(tag_id)
      end
    end

    # Store tag_id for reference
    checkbox.instance_variable_set(:@tag_id, tag_id)

    checkbox
  end
end
