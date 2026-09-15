require 'gtk3'
require 'cgi'
require 'uri'
require_relative '../domain/queue_sort'
require_relative '../domain/tag_color'
require_relative '../domain/sidebar_title'
require_relative '../domain/url_matcher'

# Sidebar view for displaying and managing the URL queue
#
# Holds no manager, repository or adapter. Everything it renders arrives
# through a `get_*` callback and everything the user asks for leaves through
# an `on_*` callback; the Framework (`BrowserWindow`) binds both to
# `Managers::QueueManager`.
#
# Which tags are being filtered on and which sort the user picked are view
# state, so they stay here. What those choices *mean* does not:
# `Managers::QueueManager#entries_for_filter` decides that an empty filter
# means "everything", and `Domain::QueueSort` owns the orderings.
class QueueListView
  attr_reader :list_widget

  # Creates a new queue list view
  #
  # @param callbacks [Hash] Data sources and intents:
  #   - :create_favicon_image => ->(favicon_data) { Gtk::Image }
  #   - :get_entries => ->(tag_ids) { Array<Domain::QueueEntry> }
  #   - :get_total_count => -> { Integer } unfiltered queue size
  #   - :get_tags_for_entry => ->(entry_id) { Array<Domain::Tag> }
  #   - :get_tag_usages => -> { Array<Domain::TagUsage> } for the filter popover
  #   - :find_tag_by_name => ->(tag_name) { Domain::Tag, nil }
  #   - :find_tag_by_id => ->(tag_id) { Domain::Tag, nil }
  #   - :on_remove_entry => ->(entry_id) { ... }
  #   - :on_move_entry => ->(entry_id, position) { truthy when the move happened }
  def initialize(callbacks = {})
    @callbacks = callbacks
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Callback invoked when queue item is clicked
    # Signature: ->(entry) { ... } where entry is a Domain::QueueEntry
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

    # Track the current drop indicator row
    @drop_indicator_row = nil

    # Set up CSS for drop indicator
    setup_drop_indicator_css

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_queue_item_clicked(row)
    end
  end

  # The callbacks below are assigned after construction rather than passed to
  # it: the sidebar they notify does not exist until the views it contains have
  # been built.

  # Sets callback to invoke when queue item is selected
  #
  # @param callback [Proc] Callback proc accepting a Domain::QueueEntry: ->(entry) { ... }
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
    tag = find_tag_by_name(tag_name)
    return unless tag

    # Set as the only active filter (replaces existing filters)
    @active_filter_tag_ids = [tag.id]
    apply_filters
  end

  # Removes the filter for a tag named by the caller
  #
  # The filter bar shows pills by name, so this is what its remove buttons
  # call -- it keeps the name-to-id lookup inside the view that owns the
  # filter state instead of exposing that state to the sidebar.
  #
  # @param tag_name [String] Tag name to stop filtering by
  # @return [void]
  def remove_filter_tag_by_name(tag_name)
    tag = find_tag_by_name(tag_name)
    return unless tag

    remove_filter_tag(tag.id)
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
      tag = @callbacks[:find_tag_by_id]&.call(tag_id)
      tag ? tag.name : nil
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
  # @param mode [Symbol] One of Domain::QueueSort::MODES
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
    entries = filtered_sorted_entries
    total_count = @callbacks[:get_total_count]&.call || 0

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
        if Domain::UrlMatcher.match?(entry.url, current_url)
          @list_widget.select_row(row)
        end
      end
    end

    @list_widget.show_all

    # Notify callback with filtered count and total count
    @on_queue_modified.call(entries.length, total_count) if @on_queue_modified
  end

  # Asks for an entry to be dropped from the queue, then redraws
  #
  # @param entry_id [Integer] Entry the user wants gone
  # @return [void]
  def remove_entry(entry_id)
    @callbacks[:on_remove_entry]&.call(entry_id)
    refresh
  end

  # Asks for an entry to be moved, then redraws with the moved row selected
  #
  # @param entry_id [Integer] Entry being dragged
  # @param position [Integer] Position it was dropped on
  # @return [void]
  def move_entry(entry_id, position)
    return unless @callbacks[:on_move_entry]&.call(entry_id, position)

    refresh
    select_entry(entry_id)
  end

  # The queue entry behind the highlighted row
  #
  # The rows are this widget's own, so nobody outside it should be reading an
  # entry off one -- they ask here instead.
  #
  # @return [Domain::QueueEntry, nil] Selected entry, or nil if none is selected
  def selected_entry
    row = @list_widget.selected_row
    row && entry_for(row)
  end

  # Highlights the row showing an entry, if it is on screen
  #
  # @param entry_id [Integer] Entry to select
  # @return [Boolean] Whether a row was found to select
  def select_entry(entry_id)
    row = @list_widget.children.find { |child| entry_for(child)&.id == entry_id }
    return false unless row

    @list_widget.select_row(row)
    true
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

  # The entry a row was built from.
  #
  # GTK rows carry no user data of their own, so `create_queue_row` stashes the
  # entry on the row it creates and this reads it back. Stashing data on a
  # widget this view owns is the GTK idiom; reaching into a widget somebody
  # else owns is what `selected_entry` and `select_entry` exist to prevent.
  #
  # @param row [Gtk::Widget] A row of this list
  # @return [Domain::QueueEntry, nil] The entry it shows
  def entry_for(row)
    row.instance_variable_get(:@queue_entry)
  end

  # @param tag_name [String] Tag name to look up
  # @return [Domain::Tag, nil] The tag, when the data source knows it
  def find_tag_by_name(tag_name)
    @callbacks[:find_tag_by_name]&.call(tag_name)
  end

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

  # Gets queue entries with current filters and sort applied
  #
  # @return [Array<Domain::QueueEntry>] Filtered and sorted entries
  def filtered_sorted_entries
    entries = @callbacks[:get_entries]&.call(@active_filter_tag_ids) || []

    Domain::QueueSort.apply(entries, @current_sort_mode)
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
  # @param entry [Domain::QueueEntry] Entry to render
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
    favicon_image = @callbacks[:create_favicon_image].call(entry.favicon_data)
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = entry.display_title
    # Ensure UTF-8 encoding for display
    title = title.dup.force_encoding('UTF-8') if title
    unless title.valid_encoding?
      title = title.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    title_label = Gtk::Label.new
    title_label.markup = Domain::SidebarTitle.markup(title)
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(entry.url)
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Tags display
    tags = @callbacks[:get_tags_for_entry]&.call(entry.id) || []
    tags_box = Gtk::Box.new(:horizontal, 8)
    tags_box.halign = :start

    if tags.length > 0
      # Sort tags alphabetically (case-insensitive)
      sorted_tags = tags.sort_by { |tag| tag.name.downcase }

      # Show first 3 tags
      visible_tags = sorted_tags.take(3)
      visible_tags.each do |tag|
        pill = create_tag_pill(tag.name)
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
      remove_entry(entry.id)
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
      entry = w.instance_variable_get(:@queue_entry)
      if entry
        # Send the entry ID as plain text (converted to string for transfer)
        selection_data.text = entry.id.to_s
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
      # Get the dropped entry ID
      dropped_id_text = selection_data.text

      if dropped_id_text && !dropped_id_text.empty?
        dropped_entry_id = dropped_id_text.to_i  # Convert back to integer
        target_entry = w.instance_variable_get(:@queue_entry)

        if target_entry && dropped_entry_id != target_entry.id
          # Move the dropped entry to the target position
          view.move_entry(dropped_entry_id, target_entry.position)
        end
      end

      # Finish the drag operation
      context.finish(true, false, time)
    end

    # Handle drag end (clear indicator if drag cancelled)
    widget.signal_connect("drag-end") do |w, context|
      view.clear_drop_indicator
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

  # Create Gdk::RGBA from tag name
  # @param tag_name [String] Tag name to generate color for
  # @return [Gdk::RGBA] RGBA color object for GTK
  def tag_color_rgba(tag_name)
    r, g, b = Domain::TagColor.rgb(tag_name)
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
    tag_usages = @callbacks[:get_tag_usages]&.call || []

    if tag_usages.empty?
      # No tags exist - show message
      no_tags_label = Gtk::Label.new("No tags available")
      no_tags_label.style_context.add_class("dim-label")
      tags_box.pack_start(no_tags_label, expand: false, fill: false, padding: 8)
    else
      # Create checkbox for each tag with usage count
      tag_usages.each do |tag_usage|
        checkbox = create_filter_checkbox(tag_usage)
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
  # @param tag_usage [Domain::TagUsage] Tag with its carrier count
  # @return [Gtk::CheckButton] Configured checkbox
  def create_filter_checkbox(tag_usage)
    tag_id = tag_usage.tag_id
    tag_name = tag_usage.name
    count = tag_usage.count

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
