require 'gtk3'

# Sidebar container managing tabs/history/queue view switching
class Sidebar
  # TODO (Phase 6): Consider moving queue reordering logic into Sidebar methods
  # to eliminate direct GTK widget manipulation from BrowserWindow
  attr_reader :widget, :visible, :mode, :width, :queue_list_widget

  # Creates a new sidebar
  #
  # @param view_components [Hash] Hash of view components:
  #   - :tab_list_view => TabListView instance
  #   - :history_list_view => HistoryListView instance
  #   - :queue_list_view => QueueListView instance
  # @param callbacks [Hash] Hash of callback procs:
  #   - :get_tabs => -> { [@tabs, @current_tab_index] }
  #   - :get_current_tab => -> { Tab or nil }
  #   - :get_queue_count => -> { Integer }
  #   - :get_paned => -> { Gtk::Paned widget }
  # @param initial_width [Integer] Initial sidebar width in pixels
  def initialize(view_components, callbacks, initial_width: 300)
    @view_components = view_components
    @callbacks = callbacks
    @width = initial_width
    @visible = true
    @mode = :tabs  # Can be :tabs, :history, or :queue

    # Expose queue_list_widget for move operations
    @queue_list_widget = @view_components[:queue_list_view].list_widget

    # Create sidebar box
    @widget = Gtk::Box.new(:vertical, 0)

    # Header container box
    @header_box = Gtk::Box.new(:horizontal, 8)
    @header_box.margin_top = 10
    @header_box.margin_bottom = 10
    @header_box.margin_start = 12
    @header_box.margin_end = 12

    # Header label
    @header = Gtk::Label.new
    @header.markup = "<b>Tabs</b>"
    @header.halign = :start
    @header.hexpand = true
    @header_box.pack_start(@header, expand: true, fill: true, padding: 0)

    # Filter button (only added to header when in queue mode)
    @filter_button = Gtk::Button.new
    @filter_button.relief = :none
    @filter_button.tooltip_text = "Filter queue by tags"

    # Filter icon using Unicode filter symbol
    filter_icon_label = Gtk::Label.new("\u{2630}")  # Trigram for Heaven (filter-like icon)
    @filter_button.add(filter_icon_label)

    # Style context for active state
    @filter_button_active = false

    # Filter button click handler
    @filter_button.signal_connect("clicked") do
      show_filter_popover if @mode == :queue
    end

    # Sort button (only added to header when in queue mode)
    @sort_button = Gtk::MenuButton.new
    @sort_button.relief = :none
    @sort_button.tooltip_text = "Sort queue entries"

    # Sort button label shows current sort mode
    @sort_button_label = Gtk::Label.new("Position")
    @sort_button.add(@sort_button_label)

    # Create sort popover
    @sort_popover = create_sort_popover
    @sort_button.popover = @sort_popover

    # NOTE: filter_button and sort_button are NOT packed into header_box here
    # They will be added/removed dynamically in update_filter_button_visibility

    @widget.pack_start(@header_box, expand: false, fill: false, padding: 0)

    # Filter bar (only added to widget when in queue mode with active filters)
    @filter_bar = Gtk::Box.new(:horizontal, 8)
    @filter_bar.margin_start = 12
    @filter_bar.margin_end = 12
    @filter_bar.margin_bottom = 8

    # "Filters:" label
    filters_label = Gtk::Label.new("Filters:")
    filters_label.style_context.add_class("dim-label")
    @filter_bar.pack_start(filters_label, expand: false, fill: false, padding: 0)

    # Container for filter tag pills (will be populated dynamically)
    @filter_pills_box = Gtk::Box.new(:horizontal, 4)
    @filter_bar.pack_start(@filter_pills_box, expand: true, fill: true, padding: 0)

    # Clear All link
    @clear_all_button = Gtk::Button.new(label: "Clear All")
    @clear_all_button.relief = :none
    @clear_all_button.signal_connect("clicked") do
      @view_components[:queue_list_view].clear_all_filters
    end
    @filter_bar.pack_start(@clear_all_button, expand: false, fill: false, padding: 0)

    # NOTE: filter_bar is NOT packed into @widget here
    # It will be added/removed dynamically in update_filter_button_visibility

    # Track if filter controls are currently in the widget tree
    @filter_controls_added = false

    # Scrolled window for list
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)

    # Container to hold tabs, history, or queue list
    @content = Gtk::Box.new(:vertical, 0)
    @content.pack_start(@view_components[:tab_list_view].list_widget,
                        expand: true, fill: true, padding: 0)

    scrolled.add(@content)
    @widget.pack_start(scrolled, expand: true, fill: true, padding: 0)

    @widget.set_size_request(300, -1)

    # Realize entire widget tree
    # This is needed for tests that don't add the sidebar to a window
    @widget.show_all

    # Filter controls are NOT in widget tree yet - they're added dynamically
    # when switching to queue mode via update_filter_button_visibility
  end

  # Shows tabs view in sidebar
  #
  # @return [void]
  def show_tabs
    # If already showing tabs sidebar, toggle it off
    if @visible && @mode == :tabs
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :tabs
    @header.markup = "<b>Tabs</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add tabs list
    @content.pack_start(@view_components[:tab_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Update filter button visibility AFTER show_all (show_all overrides visibility)
    update_filter_button_visibility

    # Refresh tabs
    tabs, current_tab_index = @callbacks[:get_tabs].call
    @view_components[:tab_list_view].refresh(tabs, current_tab_index)
  end

  # Shows history view in sidebar
  #
  # @return [void]
  def show_history
    # If already showing history sidebar, toggle it off
    if @visible && @mode == :history
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :history
    @header.markup = "<b>Browsing History</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add history list
    @content.pack_start(@view_components[:history_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Update filter button visibility AFTER show_all (show_all overrides visibility)
    update_filter_button_visibility

    # Refresh history
    @view_components[:history_list_view].refresh(50)
  end

  # Shows queue view in sidebar
  #
  # @return [void]
  def show_queue
    # If already showing queue sidebar, toggle it off
    if @visible && @mode == :queue
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :queue
    queue_count = @callbacks[:get_queue_count].call
    @header.markup = "<b>Queue (#{queue_count})</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add queue list
    @content.pack_start(@view_components[:queue_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Update filter button visibility AFTER show_all (show_all overrides visibility)
    update_filter_button_visibility

    # Refresh queue
    current_tab = @callbacks[:get_current_tab].call
    current_url = current_tab&.webview&.uri
    @view_components[:queue_list_view].refresh(current_url)
  end

  # Refreshes the currently active view
  #
  # @return [void]
  def refresh_current_view
    case @mode
    when :tabs
      tabs, current_tab_index = @callbacks[:get_tabs].call
      @view_components[:tab_list_view].refresh(tabs, current_tab_index)
    when :history
      @view_components[:history_list_view].refresh(50)
    when :queue
      current_tab = @callbacks[:get_current_tab].call
      current_url = current_tab&.webview&.uri
      @view_components[:queue_list_view].refresh(current_url)
    end
  end

  # Toggles sidebar visibility
  #
  # @return [void]
  def toggle
    if @visible
      hide_sidebar
    else
      show_sidebar
    end
  end

  # Updates the sidebar width
  #
  # @param width [Integer] New width in pixels
  # @return [void]
  def update_width(width)
    @width = width if width > 0
  end

  # Updates the queue header with counts
  # @param filtered_count [Integer] Number of entries after filtering
  # @param total_count [Integer] Total entries in queue
  def update_queue_header(filtered_count, total_count = nil)
    return unless @mode == :queue

    if total_count && filtered_count != total_count
      @header.markup = "<b>Queue (#{filtered_count}/#{total_count})</b>"
    else
      count = total_count || filtered_count
      @header.markup = "<b>Queue (#{count})</b>"
    end
  end

  # Updates filter button visual state (active/inactive)
  # @param active [Boolean] Whether filters are active
  def update_filter_button_state(active)
    @filter_button_active = active
    if active
      @filter_button.style_context.add_class("suggested-action")
    else
      @filter_button.style_context.remove_class("suggested-action")
    end
  end

  # Updates filter bar with active filter tags
  # @param tag_names [Array<String>] Names of active filter tags
  # @param queue_list_view [QueueListView] Reference for remove callbacks
  def update_filter_bar(tag_names, queue_list_view)
    # Clear existing pills
    @filter_pills_box.children.each { |child| @filter_pills_box.remove(child) }

    if tag_names.empty?
      @filter_bar.visible = false
      return
    end

    # Create pill for each active filter
    tag_names.each do |tag_name|
      pill = create_filter_bar_pill(tag_name, queue_list_view)
      @filter_pills_box.pack_start(pill, expand: false, fill: false, padding: 0)
    end

    @filter_bar.visible = true
    @filter_bar.show_all
  end

  private

  # Updates filter button visibility based on current mode
  # Adds/removes filter controls from widget tree instead of showing/hiding
  def update_filter_button_visibility
    should_show = (@mode == :queue)

    if should_show && !@filter_controls_added
      # Add filter controls to widget tree
      @header_box.pack_start(@filter_button, expand: false, fill: false, padding: 0)
      @header_box.pack_start(@sort_button, expand: false, fill: false, padding: 0)
      # Insert filter_bar after header_box (position 1)
      @widget.pack_start(@filter_bar, expand: false, fill: false, padding: 0)
      @widget.reorder_child(@filter_bar, 1)
      # Use show_all to show buttons and their child labels
      @filter_button.show_all
      @sort_button.show_all
      # Filter bar visibility is controlled by update_filter_bar based on active filters
      @filter_controls_added = true
    elsif !should_show && @filter_controls_added
      # Remove filter controls from widget tree
      @header_box.remove(@filter_button)
      @header_box.remove(@sort_button)
      @widget.remove(@filter_bar)
      @filter_controls_added = false
    end
  end

  # Delegate to queue_list_view which owns filter state
  def show_filter_popover
    @view_components[:queue_list_view].show_filter_popover(@filter_button)
  end

  # Creates a removable filter pill for the filter bar
  # @param tag_name [String] Tag name to display
  # @param queue_list_view [QueueListView] Reference for remove callback
  # @return [Gtk::Box] Box containing label and remove button
  def create_filter_bar_pill(tag_name, queue_list_view)
    # Container box
    pill_box = Gtk::Box.new(:horizontal, 2)

    # Get color from queue_list_view
    r, g, b = queue_list_view.tag_color_rgb(tag_name)

    # EventBox for background color
    event_box = Gtk::EventBox.new
    rgba = Gdk::RGBA.new(r / 255.0, g / 255.0, b / 255.0, 1.0)
    event_box.override_background_color(:normal, rgba)

    # Inner box for label + X button
    inner_box = Gtk::Box.new(:horizontal, 4)
    inner_box.margin_top = 2
    inner_box.margin_bottom = 2
    inner_box.margin_start = 6
    inner_box.margin_end = 4

    # Tag name label
    label = Gtk::Label.new(tag_name)
    label.override_color(:normal, Gdk::RGBA.new(1.0, 1.0, 1.0, 1.0))  # White text
    inner_box.pack_start(label, expand: false, fill: false, padding: 0)

    # Remove button (X)
    remove_button = Gtk::Button.new(label: "x")
    remove_button.relief = :none

    # Style the X button to be small and match text color
    css_provider = Gtk::CssProvider.new
    css_data = <<-CSS
      button {
        padding: 0px 2px;
        min-width: 0;
        min-height: 0;
        color: white;
      }
    CSS
    css_provider.load_from_data(css_data)
    remove_button.style_context.add_provider(
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )

    # Remove filter on click
    remove_button.signal_connect("clicked") do
      tag = queue_list_view.queue_manager.find_tag_by_name(tag_name)
      queue_list_view.remove_filter_tag(tag['id']) if tag
    end

    inner_box.pack_start(remove_button, expand: false, fill: false, padding: 0)

    event_box.add(inner_box)

    # Apply border radius CSS
    css_provider2 = Gtk::CssProvider.new
    css_data2 = <<-CSS
      * {
        border-radius: 3px;
      }
    CSS
    css_provider2.load_from_data(css_data2)
    event_box.style_context.add_provider(
      css_provider2,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )

    # Accessibility
    event_box.accessible.accessible_name = "Remove filter: #{tag_name}"

    pill_box.pack_start(event_box, expand: false, fill: false, padding: 0)
    pill_box
  end

  # Creates sort popover with radio buttons
  def create_sort_popover
    popover = Gtk::Popover.new

    vbox = Gtk::Box.new(:vertical, 4)
    vbox.margin_top = 8
    vbox.margin_bottom = 8
    vbox.margin_start = 12
    vbox.margin_end = 12

    # Title
    title_label = Gtk::Label.new
    title_label.markup = "<b>Sort by</b>"
    title_label.halign = :start
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # Separator
    separator = Gtk::Separator.new(:horizontal)
    vbox.pack_start(separator, expand: false, fill: false, padding: 4)

    # Radio buttons for sort options
    @sort_position_radio = Gtk::RadioButton.new(label: "Added to Queue")
    @sort_position_radio.active = true
    @sort_position_radio.signal_connect("toggled") do
      if @sort_position_radio.active?
        set_sort_mode(:position)
      end
    end
    vbox.pack_start(@sort_position_radio, expand: false, fill: false, padding: 2)

    @sort_title_radio = Gtk::RadioButton.new(member: @sort_position_radio, label: "Title")
    @sort_title_radio.signal_connect("toggled") do
      if @sort_title_radio.active?
        set_sort_mode(:title)
      end
    end
    vbox.pack_start(@sort_title_radio, expand: false, fill: false, padding: 2)

    @sort_date_radio = Gtk::RadioButton.new(member: @sort_position_radio, label: "Date Published")
    @sort_date_radio.signal_connect("toggled") do
      if @sort_date_radio.active?
        set_sort_mode(:date_published)
      end
    end
    vbox.pack_start(@sort_date_radio, expand: false, fill: false, padding: 2)

    popover.add(vbox)
    popover.show_all
    popover
  end

  # Sets sort mode and updates UI
  def set_sort_mode(mode)
    # Update button label
    label_text = case mode
      when :position then "Position"
      when :title then "Title"
      when :date_published then "Date"
    end
    @sort_button_label.text = label_text

    # Tell queue_list_view to apply new sort
    @view_components[:queue_list_view].set_sort_mode(mode)

    # Close popover
    @sort_popover.popdown
  end

  # Shows the sidebar widget
  def show_sidebar
    @widget.show_all
    paned = @callbacks[:get_paned].call
    paned.set_position(@width)
    @visible = true
    # After show_all, hide filter controls if not in queue mode
    update_filter_button_visibility
  end

  # Hides the sidebar widget
  def hide_sidebar
    @visible = false
    @widget.hide
    paned = @callbacks[:get_paned].call
    paned.set_position(0)
  end
end
