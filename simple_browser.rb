#!/usr/bin/env ruby

# Capture ARGV before GTK Application consumes it
ORIGINAL_ARGV = ARGV.dup

# IPC file for passing URLs between instances
IPC_DIR = File.join(Dir.home, '.local/share/toy-browser')
FileUtils.mkdir_p(IPC_DIR)
IPC_URL_FILE = File.join(IPC_DIR, 'pending-url')

# If we have a URL argument, write it to the IPC file
if ORIGINAL_ARGV.length > 0 && !ORIGINAL_ARGV[0].empty?
  File.write(IPC_URL_FILE, "#{ORIGINAL_ARGV[0]}\n#{Time.now.to_f}")
end

require 'gtk3'
require 'webkit2-gtk'
require 'cgi'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require_relative 'history_manager'
require_relative 'queue_manager'
require_relative 'video_popout_window'
require_relative 'lib/managers/web_context_manager'
require_relative 'lib/managers/settings_manager'
require_relative 'lib/managers/session_manager'
require_relative 'lib/managers/queue_metadata_worker'
require_relative 'lib/managers/favicon_manager'
require_relative 'lib/tab'
require_relative 'lib/ui/tab_list_view'
require_relative 'lib/ui/history_list_view'
require_relative 'lib/ui/queue_list_view'
require_relative 'lib/ui/toolbar'
require_relative 'lib/ui/sidebar'
require_relative 'lib/handlers/navigation_handler'
require_relative 'lib/handlers/mouse_handler'
require_relative 'lib/handlers/keyboard_handler'

class BrowserWindow < Gtk::Window
  def initialize
    super

    set_title("Toy Browser")
    set_default_size(1200, 768)

    # Initialize history manager
    @history_manager = HistoryManager.new

    # Initialize queue manager
    @queue_manager = QueueManager.new

    # Initialize background worker for fetching queue entry metadata
    @queue_metadata_worker = QueueMetadataWorker.new(@queue_manager)
    @queue_metadata_worker.on_metadata_fetched = -> {
      @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue
    }

    # Data directory
    @data_dir = File.join(Dir.home, '.local/share/toy-browser')
    FileUtils.mkdir_p(@data_dir)

    # Load settings
    @settings_manager = SettingsManager.new(data_dir: @data_dir)
    @session_manager = SessionManager.new(data_dir: @data_dir)
    @dark_mode = @settings_manager.dark_mode
    @sidebar_width_ratio = 0.15  # Always 15%, not persisted

    # Zen mode state
    @zen_mode = false
    @sidebar_visible_before_zen = true

    # Track last recorded visit to avoid duplicates
    @last_recorded_visit = nil

    # Apply dark mode setting
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # Tab management
    @tabs = []
    @current_tab_index = 0

    # Create web context first (needed for tabs)
    @web_context = WebContextManager.create(data_dir: @data_dir)

    # Create layout
    vbox = ::Gtk::Box.new(:vertical, 0)
    add(vbox)

    # Toolbar
    toolbar_callbacks = {
      on_sidebar_toggle: -> { toggle_sidebar },
      on_back: -> { on_back },
      on_forward: -> { on_forward },
      on_load_url: -> { @navigation_handler.navigate_to(@url_entry.text) },
      get_current_tab: -> { current_tab },  # Safe: nil during init, but callbacks only fire during user interaction
      in_zen_mode: -> { @zen_mode }
    }
    @toolbar_component = Toolbar.new(toolbar_callbacks)
    @toolbar = @toolbar_component.widget
    @url_entry = @toolbar_component.url_entry

    # Navigation handler
    navigation_callbacks = {
      get_current_tab: -> { current_tab },
      in_zen_mode: -> { @zen_mode },
      get_toolbar: -> { @toolbar }
    }
    @navigation_handler = NavigationHandler.new(navigation_callbacks)

    # Mouse handler
    mouse_callbacks = {
      get_current_tab: -> { current_tab },
      create_new_tab: ->(uri, switch_to:) { create_new_tab(uri, switch_to: switch_to) }
    }
    @mouse_handler = MouseHandler.new(mouse_callbacks)

    # Pack toolbar into main layout
    vbox.pack_start(@toolbar, expand: false, fill: false, padding: 0)

    # Keep @toolbar and @url_entry references for:
    # - Zen mode operations (lines 1209, 1219)
    # - URL updates on navigation (line 757)

    # Horizontal paned for sidebar and content
    @paned = Gtk::Paned.new(:horizontal)
    @paned.wide_handle = true  # Make the resize handle more visible
    vbox.pack_start(@paned, expand: true, fill: true, padding: 0)

    # Left sidebar for tabs
    # CRITICAL INITIALIZATION ORDERING:
    # 1. Create paned widget FIRST (done above at line ~153)
    # 2. Create view components (TabListView, HistoryListView, QueueListView)
    # 3. Create Sidebar component with view_components
    # 4. Pack sidebar into paned
    # 5. Register paned signal handler (NOW @sidebar_component exists)
    #
    # This order is required because:
    # - Paned signal handler references @sidebar_component.visible
    # - Signal handler DOES fire during initialization when @paned.set_position() is called in map-event
    # - @sidebar_component MUST exist BEFORE signal handler is registered
    # - Previous spec incorrectly stated signals only fire during user interaction

    # Create view components
    tab_list_view = TabListView.new(->(favicon_data) { create_favicon_image(favicon_data) })
    tab_list_view.on_tab_selected = ->(index) { switch_to_tab(index) }

    history_list_view = HistoryListView.new(@history_manager,
                                             ->(favicon_data) { create_favicon_image(favicon_data) })
    history_list_view.on_history_item_selected = ->(visit) {
      current_tab.webview.load_uri(visit['uri']) if current_tab
    }

    queue_list_view = QueueListView.new(@queue_manager,
                                         ->(favicon_data) { create_favicon_image(favicon_data) })
    queue_list_view.on_queue_item_selected = ->(entry) {
      current_tab.webview.load_uri(entry['url']) if current_tab
    }

    # Create sidebar component
    sidebar_callbacks = {
      get_tabs: -> { [@tabs, @current_tab_index] },
      get_current_tab: -> { current_tab },
      get_queue_count: -> { @queue_manager.count },
      get_paned: -> { @paned }
    }
    @sidebar_component = Sidebar.new(
      { tab_list_view: tab_list_view, history_list_view: history_list_view, queue_list_view: queue_list_view },
      sidebar_callbacks,
      initial_width: (1200 * @sidebar_width_ratio).to_i
    )

    # Wire queue callback AFTER sidebar creation (safe because queue isn't modified during init)
    queue_list_view.on_queue_modified = ->(count) {
      @sidebar_component.update_queue_header(count)
    }

    @sidebar = @sidebar_component.widget
    @paned.pack1(@sidebar, resize: true, shrink: true)
    # Don't set position yet - wait until window is shown

    # Track sidebar width changes - AFTER sidebar component creation
    @paned_position_set = false
    @paned.signal_connect("notify::position") do
      if @sidebar_component.visible && @paned.position > 0
        # Ignore the first change after we manually set the position
        if @paned_position_set
          @sidebar_component.update_width(@paned.position)
        end
      end
    end

    # Set the sidebar width AFTER the window is shown and GTK has done layout (only on first map)
    @initial_map_done = false
    signal_connect("map-event") do
      unless @initial_map_done
        # Calculate sidebar width based on window width (always 15%)
        window_width = allocation.width
        sidebar_width = (window_width * @sidebar_width_ratio).to_i
        @sidebar_component.update_width(sidebar_width)
        @paned.set_position(sidebar_width)
        @paned_position_set = true
        @initial_map_done = true
      end
      false
    end

    # Save settings when window is closing
    signal_connect("delete-event") do
      @settings_manager.save_settings
      false  # Allow the window to close
    end

    # Set up favicon database
    puts "DEBUG: WebContext methods containing 'favicon': #{@web_context.methods.grep(/favicon/i)}"
    puts "DEBUG: WebContext methods containing 'database': #{@web_context.methods.grep(/database/i)}"

    # Set up favicon database and manager
    begin
      @favicon_db = @web_context.favicon_database
      puts "DEBUG: Got favicon database: #{@favicon_db.inspect}"

      # Create favicon manager
      @favicon_manager = FaviconManager.new(@favicon_db, @history_manager, -> { @tabs })
      @favicon_manager.on_favicon_updated = -> { @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs }
    rescue => e
      puts "DEBUG: Error accessing favicon database: #{e.message}"
      @favicon_db = nil
      @favicon_manager = nil
    end

    # Scrolled window for webview (will swap webviews when switching tabs)
    @webview_container = Gtk::ScrolledWindow.new
    @paned.pack2(@webview_container, resize: true, shrink: false)

    # Only restore session if no URL was passed as argument
    if ORIGINAL_ARGV.empty?
      # Restore session if available, otherwise create initial tab
      session = @session_manager.load_session
      if session && session['tabs'] && !session['tabs'].empty?
        # Restore tabs from session
        session['tabs'].each do |tab_url|
          create_new_tab(tab_url)
        end

        # Restore current tab index
        if session['current_tab_index'] && session['current_tab_index'] < @tabs.length
          switch_to_tab(session['current_tab_index'])
        end
      else
        # Create initial tab
        create_new_tab("https://www.example.com")
      end
    else
      # URL will be opened by command-line handler, just create a placeholder
      create_new_tab("about:blank")
    end

    # Test mode: Write state for automated testing
    if ENV['BROWSER_TEST_MODE'] == '1'
      GLib::Idle.add do
        test_state = {
          'tabs' => @tabs.map { |tab| {'uri' => tab.uri, 'title' => tab.title} },
          'current_tab_index' => @current_tab_index,
          'dark_mode' => @settings_manager.dark_mode,
          'sidebar_visible' => @sidebar_component.visible
        }
        File.write('/tmp/browser-test-state.json', JSON.pretty_generate(test_state))
        false  # Don't repeat
      end
    end

    # Populate tabs in sidebar
    @sidebar_component.refresh_current_view

    # Cleanup on window destroy
    signal_connect("destroy") do
      # Stop the background worker
      @queue_metadata_worker.stop

      # Save session and settings
      save_current_session
      @settings_manager.save_settings
    end

    # Keyboard handler
    keyboard_callbacks = {
      toolbar_actions: {
        focus_url_entry: -> {
          @url_entry.grab_focus
          @url_entry.select_region(0, -1)
        },
        show_toolbar: -> { @toolbar.show_all },
        in_zen_mode: -> { @zen_mode }
      },
      sidebar_actions: {
        toggle: -> { @sidebar_component.toggle },
        show_tabs: -> { show_tabs_sidebar },
        show_history: -> { show_history_sidebar },
        show_queue: -> { show_queue_sidebar },
        visible: -> { @sidebar_component.visible },
        mode: -> { @sidebar_component.mode }
      },
      tab_actions: {
        create: -> { create_new_tab },
        close_current: -> { close_current_tab },
        next: -> { next_tab },
        previous: -> { previous_tab },
        move_up: -> { move_tab_up },
        move_down: -> { move_tab_down },
        get_current: -> { current_tab }
      },
      navigation_actions: {
        go_back: -> {
          if current_tab && current_tab.webview.can_go_back?
            current_tab.webview.go_back
          end
        },
        go_forward: -> {
          if current_tab && current_tab.webview.can_go_forward?
            current_tab.webview.go_forward
          end
        },
        reload: -> { current_tab.webview.reload if current_tab }
      },
      queue_actions: {
        add_current: -> { add_current_tab_to_queue },
        remove_and_next: -> { remove_from_queue_and_next },
        next_item: -> { navigate_to_next_queue_item },
        previous_item: -> { navigate_to_previous_queue_item },
        move_current_up: -> { move_current_page_up_in_queue },
        move_current_down: -> { move_current_page_down_in_queue }
      },
      zoom_actions: {
        zoom_in: -> { zoom_in },
        zoom_out: -> { zoom_out },
        reset: -> { reset_zoom }
      },
      mode_actions: {
        toggle_dark_mode: -> { toggle_dark_mode },
        toggle_zen_mode: -> { toggle_zen_mode },
        toggle_inspector: -> { toggle_inspector }
      },
      window_actions: {
        reload_browser: -> { reload_browser },
        open_new_window: -> { open_new_window },
        open_video_popout: -> { open_video_popout }
      }
    }
    @keyboard_handler = KeyboardHandler.new(keyboard_callbacks)

    # Keyboard shortcuts
    signal_connect("key-press-event") do |widget, event|
      @keyboard_handler.handle_key_press(widget, event)
    end

    # Mouse button shortcuts (back/forward buttons)
    signal_connect("button-press-event") do |widget, event|
      @mouse_handler.handle_button_press(widget, event)
    end
  end

  def current_tab
    return nil if @tabs.empty?
    @tabs[@current_tab_index]
  end

  def create_new_tab(uri = "https://www.google.com", switch_to: true)
    tab = Tab.new(@web_context, @favicon_db, uri)

    # Connect signals for this tab
    setup_tab_signals(tab)

    @tabs << tab

    # Switch to the new tab if requested
    if switch_to
      @current_tab_index = @tabs.length - 1
      switch_to_tab(@current_tab_index)
    end

    # Refresh tabs sidebar
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def close_current_tab
    return if @tabs.empty?

    # Get the tab to close
    tab_to_close = @tabs[@current_tab_index]

    # Stop the webview and clean up resources
    if tab_to_close
      # Stop loading any content
      tab_to_close.webview.stop_loading

      # Load about:blank to stop any JavaScript/media playback
      tab_to_close.webview.load_uri("about:blank")

      # Try to destroy the webview widget
      begin
        tab_to_close.webview.destroy if tab_to_close.webview.respond_to?(:destroy)
      rescue => e
        puts "DEBUG: Error destroying webview: #{e.message}"
      end
    end

    # Remove the tab
    @tabs.delete_at(@current_tab_index)

    # If that was the last tab, create a new one
    if @tabs.empty?
      create_new_tab
      return
    end

    # Adjust current_tab_index if needed
    if @current_tab_index >= @tabs.length
      @current_tab_index = @tabs.length - 1
    end

    # Switch to the adjusted current tab
    switch_to_tab(@current_tab_index)

    # Refresh tabs sidebar
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def next_tab
    return if @tabs.length <= 1

    # Move to next tab with wrapping
    @current_tab_index = (@current_tab_index + 1) % @tabs.length
    switch_to_tab(@current_tab_index)
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def previous_tab
    return if @tabs.length <= 1

    # Move to previous tab with wrapping
    @current_tab_index = (@current_tab_index - 1) % @tabs.length
    switch_to_tab(@current_tab_index)
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def move_tab_up
    return if @tabs.length <= 1
    return if @current_tab_index == 0  # Already at the top, no wrapping

    # Swap current tab with the one above it
    @tabs[@current_tab_index], @tabs[@current_tab_index - 1] =
      @tabs[@current_tab_index - 1], @tabs[@current_tab_index]

    # Update current index to follow the tab
    @current_tab_index -= 1

    # Refresh tabs sidebar to show new order
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def move_tab_down
    return if @tabs.length <= 1
    return if @current_tab_index == @tabs.length - 1  # Already at the bottom, no wrapping

    # Swap current tab with the one below it
    @tabs[@current_tab_index], @tabs[@current_tab_index + 1] =
      @tabs[@current_tab_index + 1], @tabs[@current_tab_index]

    # Update current index to follow the tab
    @current_tab_index += 1

    # Refresh tabs sidebar to show new order
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def switch_to_tab(index)
    return if index < 0 || index >= @tabs.length

    @current_tab_index = index
    tab = @tabs[index]

    # Remove old webview from container
    @webview_container.children.each do |child|
      @webview_container.remove(child)
    end

    # Add new webview to container
    @webview_container.add(tab.webview)
    @webview_container.show_all

    # Update URL bar with current tab's URI
    @url_entry.text = tab.uri || ""

    # Update window title
    update_window_title

    # Refresh tabs to show selection
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def update_window_title
    if current_tab && current_tab.title && !current_tab.title.empty?
      set_title("#{current_tab.title} - Toy Browser")
    else
      set_title("Toy Browser")
    end
  end

  def setup_tab_signals(tab)
    tab.webview.signal_connect("notify::uri") do
      next unless current_tab == tab
      on_uri_changed
    end

    tab.webview.signal_connect("notify::title") do
      next unless current_tab == tab
      on_title_changed
      update_window_title
    end

    tab.webview.signal_connect("load-changed") do |_webview, load_event|
      next unless current_tab == tab
      on_load_changed(load_event)
    end

    # Handle mouse button events on the WebView
    tab.webview.signal_connect("button-press-event") do |_webview, event|
      next false unless current_tab == tab
      @mouse_handler.handle_button_press(tab.webview, event)
    end

    # Handle Ctrl+Click to open links in new tab
    tab.webview.signal_connect("decide-policy") do |_webview, decision, decision_type|
      @mouse_handler.handle_decide_policy(tab.webview, decision, decision_type, tab)
    end

    # Handle context menu to add custom options for links
    tab.webview.signal_connect("context-menu") do |_webview, context_menu, event, hit_test_result|
      # Check if we right-clicked on a link
      if hit_test_result.link_uri
        link_uri = hit_test_result.link_uri

        # "Add to Queue" action
        queue_action = Gio::SimpleAction.new("add-to-queue-#{link_uri.hash.abs}", nil)
        queue_action.signal_connect("activate") do
          # Add the link to the queue
          result = @queue_manager.add(link_uri, nil, nil)

          case result
          when :added
            puts "Added to queue: #{link_uri}"
            # Refresh queue if visible
            @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue

            # Enqueue work for background worker to fetch title and favicon
            entry = @queue_manager.find_by_url(link_uri)
            if entry
              @queue_metadata_worker.enqueue(entry['id'], link_uri)
            end
          when :already_exists
            puts "Already in queue: #{link_uri}"
          when :invalid_url
            warn "Cannot add invalid URL to queue"
          end
        end

        queue_item = WebKit2Gtk::ContextMenuItem.new(queue_action, "Add to Queue", nil)
        context_menu.prepend(queue_item)

        # "Open Link in New Tab" action
        open_tab_action = Gio::SimpleAction.new("open-in-new-tab-#{link_uri.hash.abs}", nil)
        open_tab_action.signal_connect("activate") do
          create_new_tab(link_uri, switch_to: false)
          puts "Opened in new tab: #{link_uri}"
        end

        open_tab_item = WebKit2Gtk::ContextMenuItem.new(open_tab_action, "Open Link in New Tab", nil)
        context_menu.prepend(open_tab_item)

        # Add separator after our custom items
        separator = WebKit2Gtk::ContextMenuItem.new()
        context_menu.insert(separator, 2)
      end

      false  # Let the default menu show
    end
  end


  def on_uri_changed
    return unless current_tab
    uri = current_tab.webview.uri
    return unless uri

    # Update URL bar only
    # Don't record history here - wait for title to load in on_title_changed
    @toolbar_component.update_url(uri)
    current_tab.uri = uri

    # Update queue highlight if queue sidebar is visible
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue
  end

  def on_title_changed
    return unless current_tab

    # When title changes (e.g., YouTube video loads after URL change),
    # record/update the visit with the new title
    uri = current_tab.webview.uri
    title = current_tab.webview.title

    if uri && !uri.empty? && title && !title.empty?
      current_tab.title = title
      current_tab.uri = uri

      # Only record if this is a different URI or title than last recorded
      visit_key = "#{uri}|#{title}"
      unless @last_recorded_visit == visit_key
        @history_manager.record_visit(uri, title)
        @last_recorded_visit = visit_key

        # Try to fetch favicon for this page (important for SPAs like YouTube)
        @favicon_manager.fetch_and_save_favicon(uri) if @favicon_manager
      end

      # Refresh tabs to update title in sidebar
      @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
    end
  end

  def on_back
    current_tab.webview.go_back if current_tab
  end

  def on_forward
    current_tab.webview.go_forward if current_tab
  end

  def show_tabs_sidebar
    @sidebar_component.show_tabs
  end

  def show_history_sidebar
    @sidebar_component.show_history
  end

  def show_queue_sidebar
    @sidebar_component.show_queue
  end

  def add_current_tab_to_queue
    return unless current_tab

    url = current_tab.uri
    title = current_tab.title
    favicon_data = current_tab.favicon_data

    result = @queue_manager.add(url, title, favicon_data)

    case result
    when :added
      # Show notification or update queue if visible
      if @sidebar_component.mode == :queue
        @sidebar_component.refresh_current_view
      end
      puts "Added to queue: #{title}"
    when :already_exists
      puts "Already in queue: #{title}"
    when :invalid_url
      warn "Cannot add invalid URL to queue"
    end
  end

  def remove_from_queue_and_next
    return unless current_tab

    url = current_tab.uri

    # Remove current URL from queue and get the next entry
    next_entry = @queue_manager.remove_by_url(url)

    # Refresh queue if visible
    if @sidebar_component.mode == :queue
      @sidebar_component.refresh_current_view
    end

    # Navigate to next entry if it exists
    if next_entry
      current_tab.webview.load_uri(next_entry['url'])
      puts "Removed from queue, navigating to: #{next_entry['title'] || next_entry['url']}"
    else
      puts "Removed from queue, no more entries"
    end
  end

  def move_selected_queue_entry_up
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue

    # Get the currently selected row
    selected_row = @sidebar_component.queue_list_widget.selected_row
    return unless selected_row

    # Get the entry data
    entry = selected_row.instance_variable_get(:@queue_entry)
    return unless entry

    # Move up in the queue
    if @queue_manager.move_up(entry['id'])
      # Refresh the queue
      @sidebar_component.refresh_current_view

      # Find and select the row that now contains this entry
      @sidebar_component.queue_list_widget.children.each do |row|
        row_entry = row.instance_variable_get(:@queue_entry)
        if row_entry && row_entry['id'] == entry['id']
          @sidebar_component.queue_list_widget.select_row(row)
          break
        end
      end

      puts "Moved up: #{entry['title'] || entry['url']}"
    end
  end

  def move_selected_queue_entry_down
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue

    # Get the currently selected row
    selected_row = @sidebar_component.queue_list_widget.selected_row
    return unless selected_row

    # Get the entry data
    entry = selected_row.instance_variable_get(:@queue_entry)
    return unless entry

    # Move down in the queue
    if @queue_manager.move_down(entry['id'])
      # Refresh the queue
      @sidebar_component.refresh_current_view

      # Find and select the row that now contains this entry
      @sidebar_component.queue_list_widget.children.each do |row|
        row_entry = row.instance_variable_get(:@queue_entry)
        if row_entry && row_entry['id'] == entry['id']
          @sidebar_component.queue_list_widget.select_row(row)
          break
        end
      end

      puts "Moved down: #{entry['title'] || entry['url']}"
    end
  end

  def navigate_to_next_queue_item
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Get all queue entries
    entries = @queue_manager.all
    return if entries.empty?

    # Find current URL in queue
    current_index = entries.find_index { |e| e['url'] == current_url }

    if current_index
      # Navigate to next entry (wrap around to first if at end)
      next_index = (current_index + 1) % entries.length
      next_entry = entries[next_index]
    else
      # Current URL not in queue, navigate to first entry
      next_entry = entries.first
    end

    # Navigate to the next entry
    current_tab.webview.load_uri(next_entry['url'])
    puts "Navigated to next queue item: #{next_entry['title'] || next_entry['url']}"
  end

  def navigate_to_previous_queue_item
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Get all queue entries
    entries = @queue_manager.all
    return if entries.empty?

    # Find current URL in queue
    current_index = entries.find_index { |e| e['url'] == current_url }

    if current_index
      # Navigate to previous entry (wrap around to last if at beginning)
      prev_index = (current_index - 1) % entries.length
      prev_entry = entries[prev_index]
    else
      # Current URL not in queue, navigate to last entry
      prev_entry = entries.last
    end

    # Navigate to the previous entry
    current_tab.webview.load_uri(prev_entry['url'])
    puts "Navigated to previous queue item: #{prev_entry['title'] || prev_entry['url']}"
  end

  def move_current_page_up_in_queue
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Find the current URL in the queue
    entry = @queue_manager.find_by_url(current_url)
    return unless entry

    # Move up in the queue
    if @queue_manager.move_up(entry['id'])
      @sidebar_component.refresh_current_view
      puts "Moved current page up in queue: #{entry['title'] || entry['url']}"
    end
  end

  def move_current_page_down_in_queue
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Find the current URL in the queue
    entry = @queue_manager.find_by_url(current_url)
    return unless entry

    # Move down in the queue
    if @queue_manager.move_down(entry['id'])
      @sidebar_component.refresh_current_view
      puts "Moved current page down in queue: #{entry['title'] || entry['url']}"
    end
  end

  def create_favicon_image(favicon_data)
    if favicon_data && !favicon_data.empty?
      begin
        # Load PNG data into a pixbuf
        loader = GdkPixbuf::PixbufLoader.new
        loader.write(favicon_data)
        loader.close
        pixbuf = loader.pixbuf

        # Scale to 16x16
        if pixbuf
          scaled = pixbuf.scale_simple(16, 16, :bilinear)
          return Gtk::Image.new(pixbuf: scaled)
        end
      rescue => e
        warn "Failed to load favicon: #{e.message}"
      end
    end

    # Default icon if no favicon or error
    Gtk::Image.new(icon_name: "text-html", size: :menu)
  end

  def on_load_changed(load_event)
    return unless current_tab

    if load_event == :finished
      uri = current_tab.webview.uri
      title = current_tab.webview.title

      if uri && !uri.empty?
        # Only record if this is a different URI or title than last recorded
        visit_key = "#{uri}|#{title}"
        unless @last_recorded_visit == visit_key
          @history_manager.record_visit(uri, title)
          @last_recorded_visit = visit_key

          # Try to fetch favicon for this page
          @favicon_manager.fetch_and_save_favicon(uri) if @favicon_manager
        end
      end
    end
  end

  def toggle_sidebar
    @sidebar_component.toggle
  end

  def toggle_zen_mode
    if @zen_mode
      # Exit zen mode - show toolbar and restore sidebar state
      @toolbar.show_all
      if @sidebar_visible_before_zen
        # Directly manipulate widget to avoid changing @visible flag
        # (zen mode is temporary override, not user preference change)
        @sidebar_component.widget.show_all
        @paned.set_position(@sidebar_component.width)
      end
      @zen_mode = false
    else
      # Enter zen mode - hide toolbar and sidebar
      @sidebar_visible_before_zen = @sidebar_component.visible
      @toolbar.hide

      if @sidebar_component.visible
        # Directly manipulate widget to avoid changing @visible flag
        # (zen mode is temporary override, not user preference change)
        @sidebar_component.widget.hide
        @paned.set_position(0)
      end

      @zen_mode = true
    end
  end

  def toggle_dark_mode
    @settings_manager.toggle_dark_mode
    @dark_mode = @settings_manager.dark_mode

    # Toggle GTK theme variant (affects browser UI)
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # Save settings
    @settings_manager.save_settings

    puts @dark_mode ? "🌙 Dark mode enabled" : "☀️  Light mode enabled"
  end

  def toggle_inspector
    return unless current_tab

    inspector = current_tab.webview.inspector
    if inspector.attached?
      inspector.close
    else
      inspector.show
    end
  end

  def zoom_in
    return unless current_tab

    current_zoom = current_tab.webview.zoom_level
    new_zoom = [current_zoom + 0.1, 5.0].min  # Max 500%
    current_tab.webview.zoom_level = new_zoom
    puts "Zoom: #{(new_zoom * 100).round}%"
  end

  def zoom_out
    return unless current_tab

    current_zoom = current_tab.webview.zoom_level
    new_zoom = [current_zoom - 0.1, 0.25].max  # Min 25%
    current_tab.webview.zoom_level = new_zoom
    puts "Zoom: #{(new_zoom * 100).round}%"
  end

  def reset_zoom
    return unless current_tab

    current_tab.webview.zoom_level = 1.0
    puts "Zoom: 100%"
  end

  def open_new_window
    # Create a new browser window with the same application
    app = self.application
    if app
      new_window = BrowserWindow.new
      new_window.set_application(app)
      new_window.show_all
    end
  end

  def open_video_popout
    return unless current_tab

    # Get the current URL
    url = current_tab.uri
    return unless url

    # Only works for YouTube videos currently
    if url.include?("youtube.com/watch")
      popout = VideoPopoutWindow.new(url, @web_context)
      popout.set_application(self.application) if self.application
      puts "📺 Video popout opened for: #{url}"
    else
      puts "⚠️  Video popout currently only works with YouTube videos"
    end
  end

  def reload_browser
    puts "Reloading browser with latest code..."

    # Save current session (tab URLs)
    save_current_session

    # Spawn a new browser process with the same script
    script_path = File.expand_path($PROGRAM_NAME)
    spawn("ruby", script_path)

    # Close this window (will quit the application)
    close
  end

  # Helper method to save current session (private - only called internally)
  private def save_current_session
    # Collect all tab URLs
    tab_urls = @tabs.map { |tab| tab.uri || "https://www.google.com" }
    @session_manager.save_session(tab_urls, @current_tab_index)
  end

end

# Main application
app = Gtk::Application.new("com.example.browser", Gio::ApplicationFlags::HANDLES_OPEN | Gio::ApplicationFlags::HANDLES_COMMAND_LINE)

# Store reference to the main window
main_window = nil

app.signal_connect "activate" do |application|
  if main_window.nil?
    # First launch - create new window
    main_window = BrowserWindow.new
    main_window.set_application(application)
    main_window.show_all

    # Set up IPC file monitoring for URLs from other instances
    last_ipc_check = Time.now.to_f
    GLib::Timeout.add(500) do  # Check every 500ms
      if File.exist?(IPC_URL_FILE)
        begin
          content = File.read(IPC_URL_FILE)
          url, timestamp = content.split("\n")
          timestamp = timestamp.to_f

          # Only process if this is a new URL (timestamp after last check)
          if timestamp > last_ipc_check
            main_window.create_new_tab(url)
            main_window.present
            last_ipc_check = timestamp
            # Delete the file after processing
            File.delete(IPC_URL_FILE)
          end
        rescue => e
          warn "Error reading IPC file: #{e.message}"
        end
      end
      true  # Continue timer
    end
  else
    # Window already exists - just present it
    main_window.present
  end
end

app.signal_connect "command-line" do |application, command_line|
  # Get or create the main window
  if main_window.nil?
    application.activate
  end

  # Check if a URL was passed in ORIGINAL_ARGV
  if ORIGINAL_ARGV.length > 0 && !ORIGINAL_ARGV[0].to_s.empty?
    url = ORIGINAL_ARGV[0]
    begin
      tabs = main_window.instance_variable_get(:@tabs)
      first_tab_uri = tabs.first&.uri

      # If the first tab is about:blank, navigate it to the URL instead of creating a new tab
      if first_tab_uri == "about:blank"
        tabs.first.webview.load_uri(url)
      else
        # Otherwise create a new tab
        main_window.create_new_tab(url)
      end

      # Clear ORIGINAL_ARGV so we don't re-open it on next signal
      ORIGINAL_ARGV.clear
    rescue => e
      warn "Error loading URL: #{e.message}"
    end
  end

  # Bring window to front
  main_window.present if main_window

  0  # Return status code
end

app.signal_connect "open" do |application, files, hint|
  # Get or create the main window
  if main_window.nil?
    main_window = BrowserWindow.new
    main_window.set_application(application)
    main_window.show_all
  end

  # Open each file/URL as a new tab
  files.each do |file|
    url = file.uri
    begin
      main_window.create_new_tab(url)
    rescue => e
      warn "Error creating tab: #{e.message}"
    end
  end

  # Bring window to front
  main_window.present
end

app.run
