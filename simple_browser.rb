#!/usr/bin/env ruby

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

class Tab
  attr_reader :webview, :list_box_row
  attr_accessor :title, :uri, :favicon_data

  def initialize(web_context, favicon_db, initial_uri = "https://www.google.com")
    @webview = WebKit2Gtk::WebView.new(context: web_context)
    @title = "New Tab"
    @uri = initial_uri
    @favicon_data = nil
    @favicon_db = favicon_db
    @list_box_row = nil  # Will be set when added to sidebar

    # Enable developer tools and experimental features
    settings = @webview.settings
    settings.enable_developer_extras = true

    # Enable experimental features for modern web compatibility
    begin
      experimental_features = WebKit2Gtk::Settings.experimental_features

      # OPFS support (needed for 1Password and similar apps)
      opfs_features = ['StorageAPI', 'FileSystemAccess', 'FileSystemWritableStream', 'AccessHandle']

      # Standard features enabled by default in Safari
      safari_standard = ['PopoverAttribute', 'WebShareFileAPI', 'ViewTransitions',
                         'CSSUnprefixedBackdropFilter', 'ServiceWorkers', 'CSSContentVisibility']

      # Cross-browser standard features
      cross_browser_standard = ['BroadcastChannel', 'CompressionStream', 'CSSOMViewSmoothScrolling',
                                'LazyImageLoading', 'Notifications', 'PermissionsAPI',
                                'WebLocksAPI', 'URLPatternAPI']

      features_to_enable = opfs_features + safari_standard + cross_browser_standard

      features_to_enable.each do |feature_id|
        # Find the feature by iterating through the FeatureList
        feature = nil
        (0...experimental_features.length).each do |i|
          f = experimental_features.get(i)
          if f.identifier == feature_id
            feature = f
            break
          end
        end

        if feature
          settings.set_feature_enabled(feature, true)
        end
      end
    rescue => e
      warn "Could not enable experimental features: #{e.message}"
    end

    # Connect signals
    setup_signals

    # Load initial URI
    @webview.load_uri(initial_uri)
  end

  def setup_signals
    @webview.signal_connect("notify::uri") do
      @uri = @webview.uri
      update_list_box_row if @list_box_row
    end

    @webview.signal_connect("notify::title") do
      @title = @webview.title || "Untitled"
      update_list_box_row if @list_box_row
    end
  end

  def update_list_box_row
    # This will be called to refresh the tab's appearance in the sidebar
    # The actual implementation will be in BrowserWindow
  end
end

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
    @favicon_fetch_queue = Thread::Queue.new
    @favicon_worker_running = true
    @favicon_worker = Thread.new { favicon_worker_loop }

    # Data directory
    @data_dir = File.join(Dir.home, '.local/share/toy-browser')
    FileUtils.mkdir_p(@data_dir)

    # Load settings
    load_settings

    # Calculate initial sidebar width from ratio (using default window width)
    # This will be recalculated when the window is actually shown
    @sidebar_width = (1200 * @sidebar_width_ratio).to_i

    # Sidebar state
    @sidebar_visible = true
    @sidebar_mode = :tabs  # Can be :tabs, :history, or :queue

    # Zen mode state
    @zen_mode = false
    @sidebar_visible_before_zen = true

    # Track last recorded visit to avoid duplicates
    @last_recorded_visit = nil

    # Favicon debouncing - track largest favicon per URL
    @favicon_timers = {}      # url => GLib timeout source ID
    @favicon_candidates = {}  # url => {size, surface}

    # Apply dark mode setting
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # Tab management
    @tabs = []
    @current_tab_index = 0

    # Create web context first (needed for tabs)
    @web_context = create_web_context

    # Create layout
    vbox = ::Gtk::Box.new(:vertical, 0)
    add(vbox)

    # Toolbar
    @toolbar = ::Gtk::Box.new(:horizontal, 5)
    @toolbar.margin_top = 5
    @toolbar.margin_bottom = 5
    @toolbar.margin_start = 5
    @toolbar.margin_end = 5
    vbox.pack_start(@toolbar, expand: false, fill: false, padding: 0)

    # Sidebar toggle button
    @sidebar_toggle = ::Gtk::Button.new(label: "☰")
    @sidebar_toggle.signal_connect("clicked") { toggle_sidebar }
    @toolbar.pack_start(@sidebar_toggle, expand: false, fill: false, padding: 0)

    # Back button
    @back_button = ::Gtk::Button.new(label: "⬅")
    @back_button.signal_connect("clicked") { on_back }
    @toolbar.pack_start(@back_button, expand: false, fill: false, padding: 0)

    # Forward button
    @forward_button = ::Gtk::Button.new(label: "➡")
    @forward_button.signal_connect("clicked") { on_forward }
    @toolbar.pack_start(@forward_button, expand: false, fill: false, padding: 0)

    # URL entry
    @url_entry = ::Gtk::Entry.new
    @url_entry.text = "https://www.example.com"
    @url_entry.signal_connect("activate") { on_load_url }

    # Handle ESC key in URL entry
    @url_entry.signal_connect("key-press-event") do |widget, event|
      if event.keyval == Gdk::Keyval::KEY_Escape
        # Restore current tab's URL
        if current_tab && current_tab.webview.uri
          @url_entry.text = current_tab.webview.uri
        end

        # In zen mode, hide toolbar after ESC
        if @zen_mode
          @toolbar.hide
        end

        # Remove focus from URL entry
        current_tab.webview.grab_focus if current_tab

        true  # Event handled
      else
        false  # Let other handlers process
      end
    end

    @toolbar.pack_start(@url_entry, expand: true, fill: true, padding: 0)

    # Go button
    go_button = ::Gtk::Button.new(label: "Go")
    go_button.signal_connect("clicked") { on_load_url }
    @toolbar.pack_start(go_button, expand: false, fill: false, padding: 0)

    # Horizontal paned for sidebar and content
    @paned = Gtk::Paned.new(:horizontal)
    @paned.wide_handle = true  # Make the resize handle more visible
    vbox.pack_start(@paned, expand: true, fill: true, padding: 0)

    # Left sidebar for tabs
    @sidebar = create_sidebar
    @paned.pack1(@sidebar, resize: true, shrink: true)
    # Don't set position yet - wait until window is shown

    # Track sidebar width changes (just update @sidebar_width, don't save yet)
    @paned_position_set = false
    @paned.signal_connect("notify::position") do
      if @sidebar_visible && @paned.position > 0
        # Ignore the first change after we manually set the position
        if @paned_position_set
          old_width = @sidebar_width
          @sidebar_width = @paned.position
          if old_width != @sidebar_width
            puts "DEBUG: Paned position changed: #{old_width} -> #{@sidebar_width}"
          end
        end
      end
    end

    # Set the sidebar width AFTER the window is shown and GTK has done layout
    signal_connect("map-event") do
      # Calculate sidebar width based on actual window width and saved ratio
      window_width = allocation.width
      @sidebar_width = (window_width * @sidebar_width_ratio).to_i
      puts "DEBUG: Window mapped (width: #{window_width}), setting paned position to: #{@sidebar_width} (ratio: #{@sidebar_width_ratio})"
      @paned.set_position(@sidebar_width)
      @paned_position_set = true
      false
    end

    # Save settings when window is closing
    signal_connect("delete-event") do
      puts "DEBUG: Window closing, saving sidebar width: #{@sidebar_width}"
      save_settings
      false  # Allow the window to close
    end

    # Set up favicon database
    puts "DEBUG: WebContext methods containing 'favicon': #{@web_context.methods.grep(/favicon/i)}"
    puts "DEBUG: WebContext methods containing 'database': #{@web_context.methods.grep(/database/i)}"

    # Try to access favicon_database as a property
    begin
      @favicon_db = @web_context.favicon_database
      puts "DEBUG: Got favicon database: #{@favicon_db.inspect}"
      @favicon_db.signal_connect("favicon-changed") do |_db, page_uri, favicon_uri|
        on_favicon_changed(page_uri, favicon_uri)
      end
    rescue => e
      puts "DEBUG: Error accessing favicon database: #{e.message}"
      @favicon_db = nil
    end

    # Scrolled window for webview (will swap webviews when switching tabs)
    @webview_container = Gtk::ScrolledWindow.new
    @paned.pack2(@webview_container, resize: true, shrink: false)

    # Restore session if available, otherwise create initial tab
    session = load_session
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

    # Populate tabs in sidebar
    refresh_tabs

    # Cleanup on window destroy
    signal_connect("destroy") do
      # Stop the background worker
      @favicon_worker_running = false
      @favicon_fetch_queue.push(nil)  # Unblock the worker if it's waiting
      @favicon_worker.join(1) if @favicon_worker&.alive?  # Wait up to 1 second

      # Save session and settings
      save_session
      save_settings
    end

    # Keyboard shortcuts
    signal_connect("key-press-event") do |widget, event|
      if event.state.control_mask? && event.state.shift_mask?
        # Ctrl+Shift combinations
        case event.keyval
        when Gdk::Keyval::KEY_R
          # Ctrl+Shift+R: Reload browser code
          reload_browser
          true  # Event handled
        when Gdk::Keyval::KEY_P
          # Ctrl+Shift+P: Video popout
          open_video_popout
          true  # Event handled
        when Gdk::Keyval::KEY_Q
          # Ctrl+Shift+Q: Add current tab to queue
          add_current_tab_to_queue
          true  # Event handled
        when Gdk::Keyval::KEY_Tab, Gdk::Keyval::KEY_ISO_Left_Tab
          # Ctrl+Shift+Tab: Previous tab (or previous queue item if queue sidebar is open)
          if @sidebar_visible && @sidebar_mode == :queue
            navigate_to_previous_queue_item
          else
            previous_tab
          end
          true  # Event handled
        when Gdk::Keyval::KEY_Page_Down
          # Ctrl+Shift+PageDown: Move tab down (or move current page down in queue if queue sidebar is open)
          if @sidebar_visible && @sidebar_mode == :queue
            move_current_page_down_in_queue
          else
            move_tab_down
          end
          true  # Event handled
        when Gdk::Keyval::KEY_Page_Up
          # Ctrl+Shift+PageUp: Move tab up (or move current page up in queue if queue sidebar is open)
          if @sidebar_visible && @sidebar_mode == :queue
            move_current_page_up_in_queue
          else
            move_tab_up
          end
          true  # Event handled
        else
          false  # Event not handled
        end
      elsif event.state.control_mask? && !event.state.mod1_mask?
        case event.keyval
        when Gdk::Keyval::KEY_l
          # Ctrl+L: Focus and select URL bar
          # In zen mode, show toolbar temporarily
          if @zen_mode
            @toolbar.show_all
          end
          @url_entry.grab_focus
          @url_entry.select_region(0, -1)
          true  # Event handled
        when Gdk::Keyval::KEY_b
          # Ctrl+B: Toggle sidebar (unless in zen mode)
          toggle_sidebar unless @zen_mode
          true  # Event handled
        when Gdk::Keyval::KEY_d
          # Ctrl+D: Toggle dark mode
          toggle_dark_mode
          true  # Event handled
        when Gdk::Keyval::KEY_r
          # Ctrl+R: Refresh page
          current_tab.webview.reload if current_tab
          true  # Event handled
        when Gdk::Keyval::KEY_t
          # Ctrl+T: New tab
          create_new_tab
          true  # Event handled
        when Gdk::Keyval::KEY_w
          # Ctrl+W: Close current tab
          close_current_tab
          true  # Event handled
        when Gdk::Keyval::KEY_h
          # Ctrl+H: Show history in sidebar
          show_history_sidebar
          true  # Event handled
        when Gdk::Keyval::KEY_q
          # Ctrl+Q: Show queue in sidebar
          show_queue_sidebar
          true  # Event handled
        when Gdk::Keyval::KEY_e
          # Ctrl+E: Show tabs in sidebar
          show_tabs_sidebar
          true  # Event handled
        when Gdk::Keyval::KEY_n
          # Ctrl+N: New window
          open_new_window
          true  # Event handled
        when Gdk::Keyval::KEY_Tab
          # Ctrl+Tab: Next tab (or next queue item if queue sidebar is open)
          if @sidebar_visible && @sidebar_mode == :queue
            navigate_to_next_queue_item
          else
            next_tab
          end
          true  # Event handled
        when Gdk::Keyval::KEY_bracketleft
          # Ctrl+[: Back
          if current_tab && current_tab.webview.can_go_back?
            current_tab.webview.go_back
          end
          true  # Event handled
        when Gdk::Keyval::KEY_bracketright
          # Ctrl+]: Forward
          if current_tab && current_tab.webview.can_go_forward?
            current_tab.webview.go_forward
          end
          true  # Event handled
        else
          false  # Event not handled
        end
      elsif event.state.control_mask? && event.state.mod1_mask?
        # Ctrl+Alt combinations
        case event.keyval
        when Gdk::Keyval::KEY_q
          # Ctrl+Alt+Q: Remove current URL from queue and navigate to next
          remove_from_queue_and_next
          true  # Event handled
        else
          false  # Event not handled
        end
      else
        case event.keyval
        when Gdk::Keyval::KEY_F11
          # F11: Toggle zen mode
          toggle_zen_mode
          true  # Event handled
        when Gdk::Keyval::KEY_F12
          # F12: Toggle web inspector
          toggle_inspector
          true  # Event handled
        else
          false  # Event not handled
        end
      end
    end

    # Mouse button shortcuts (back/forward buttons)
    signal_connect("button-press-event") do |widget, event|
      # Debug: Show ALL button presses to see what we're getting
      puts "DEBUG: Mouse button pressed: #{event.button}"

      case event.button
      when 4, 6, 8
        # Mouse back button (trying 4, 6, and 8)
        puts "DEBUG: Back button detected (button #{event.button})"
        if current_tab && current_tab.webview.can_go_back?
          current_tab.webview.go_back
          puts "DEBUG: Navigated back"
        else
          puts "DEBUG: Cannot go back"
        end
        true  # Event handled
      when 5, 7, 9
        # Mouse forward button (trying 5, 7, and 9)
        puts "DEBUG: Forward button detected (button #{event.button})"
        if current_tab && current_tab.webview.can_go_forward?
          current_tab.webview.go_forward
          puts "DEBUG: Navigated forward"
        else
          puts "DEBUG: Cannot go forward"
        end
        true  # Event handled
      else
        false  # Event not handled
      end
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
    refresh_tabs
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
    refresh_tabs
  end

  def next_tab
    return if @tabs.length <= 1

    # Move to next tab with wrapping
    @current_tab_index = (@current_tab_index + 1) % @tabs.length
    switch_to_tab(@current_tab_index)
    refresh_tabs
  end

  def previous_tab
    return if @tabs.length <= 1

    # Move to previous tab with wrapping
    @current_tab_index = (@current_tab_index - 1) % @tabs.length
    switch_to_tab(@current_tab_index)
    refresh_tabs
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
    refresh_tabs
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
    refresh_tabs
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
    refresh_tabs
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

      case event.button
      when 4, 6, 8
        if tab.webview.can_go_back?
          tab.webview.go_back
          true
        else
          false
        end
      when 5, 7, 9
        if tab.webview.can_go_forward?
          tab.webview.go_forward
          true
        else
          false
        end
      else
        false
      end
    end

    # Handle Ctrl+Click to open links in new tab
    tab.webview.signal_connect("decide-policy") do |_webview, decision, decision_type|
      if decision_type == :navigation_action
        navigation_action = decision.navigation_action
        modifiers = navigation_action.modifiers

        # Check if Ctrl key is pressed
        # Convert modifiers to integer and check for CONTROL_MASK
        ctrl_pressed = (modifiers.to_i & Gdk::ModifierType::CONTROL_MASK.to_i) != 0

        if ctrl_pressed
          # Get the URI being navigated to
          uri_request = navigation_action.request
          uri = uri_request.uri

          # Only handle http/https links
          if uri && (uri.start_with?("http://") || uri.start_with?("https://"))
            # Ignore this navigation in the current tab
            decision.ignore

            # Open in new tab (but don't switch to it)
            create_new_tab(uri, switch_to: false)

            true  # Stop signal propagation
          else
            false  # Let other handlers process
          end
        else
          false  # Let the navigation proceed normally
        end
      else
        false  # Not a navigation action, let it proceed
      end
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
            refresh_queue if @sidebar_mode == :queue

            # Enqueue work for background worker to fetch title and favicon
            entry = @queue_manager.find_by_url(link_uri)
            if entry
              @favicon_fetch_queue.push({id: entry['id'], url: link_uri})
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

  def on_load_url
    return unless current_tab

    text = @url_entry.text.strip

    # Check if it looks like a URL (has a TLD and no spaces)
    # or if it already starts with a protocol
    if text.start_with?("http://", "https://")
      url = text
    elsif text.match?(/^[\w-]+\.[\w.-]+/) && !text.include?(' ')
      # Looks like a domain (e.g., "example.com" or "github.com")
      url = "https://#{text}"
    else
      # Treat as a search query
      query = CGI.escape(text)
      url = "https://www.google.com/search?q=#{query}"
    end

    current_tab.webview.load_uri(url)

    # In zen mode, hide toolbar after submitting URL
    if @zen_mode
      @toolbar.hide
    end
  end

  def on_uri_changed
    return unless current_tab
    uri = current_tab.webview.uri
    return unless uri

    # Update URL bar only
    # Don't record history here - wait for title to load in on_title_changed
    @url_entry.text = uri
    current_tab.uri = uri

    # Update queue highlight if queue sidebar is visible
    refresh_queue if @sidebar_mode == :queue
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
        fetch_and_save_favicon(uri)
      end

      # Refresh tabs to update title in sidebar
      refresh_tabs
    end
  end

  def on_favicon_changed(page_uri, favicon_uri)
    return unless @favicon_db

    puts "DEBUG: Favicon changed for page: #{page_uri}"
    puts "DEBUG: Favicon URI: #{favicon_uri}"

    # Favicon changed - try to save it for the current page
    fetch_and_save_favicon(page_uri)
  end

  def fetch_and_save_favicon(page_uri)
    return unless @favicon_db

    # Get the favicon asynchronously from the database
    @favicon_db.get_favicon(page_uri, nil) do |_object, result|
      begin
        surface = @favicon_db.get_favicon_finish(result)

        if surface
          puts "DEBUG: Got favicon surface for #{page_uri}"
          # Convert to PNG to check size
          favicon_data = surface_to_png(surface)

          if favicon_data
            size = favicon_data.bytesize

            # Track largest favicon seen for this URL
            current_candidate = @favicon_candidates[page_uri]
            if !current_candidate || size > current_candidate[:size]
              puts "DEBUG: New largest favicon candidate: #{size} bytes (previous: #{current_candidate ? current_candidate[:size] : 0} bytes)"
              @favicon_candidates[page_uri] = {size: size, surface: surface}
            end

            # Cancel previous timer if exists
            if @favicon_timers[page_uri]
              GLib::Source.remove(@favicon_timers[page_uri])
            end

            # Set debounce timer - save after 300ms of silence
            @favicon_timers[page_uri] = GLib::Timeout.add(300) do
              # Save the largest favicon we saw
              candidate = @favicon_candidates[page_uri]
              if candidate
                puts "DEBUG: Debounce timer fired - saving favicon (#{candidate[:size]} bytes) for #{page_uri}"
                save_favicon_data(page_uri, candidate[:surface])
                @favicon_candidates.delete(page_uri)
                @favicon_timers.delete(page_uri)
              end
              false  # Don't repeat
            end
          end
        else
          puts "DEBUG: No favicon for #{page_uri}, trying root domain..."
          # Try to get favicon from root domain as fallback
          try_root_domain_favicon(page_uri)
        end
      rescue => e
        if e.message.include?("Unknown favicon")
          puts "DEBUG: No favicon for #{page_uri}, trying root domain..."
          try_root_domain_favicon(page_uri)
        else
          puts "DEBUG: Error getting favicon for #{page_uri}: #{e.message}"
        end
      end
    end
  end

  def try_root_domain_favicon(page_uri)
    return unless @favicon_db

    begin
      uri = URI.parse(page_uri)
      root_uri = "#{uri.scheme}://#{uri.host}/"

      return if root_uri == page_uri  # Already tried root domain

      puts "DEBUG: Trying favicon from #{root_uri}"

      @favicon_db.get_favicon(root_uri, nil) do |_object, result|
        begin
          surface = @favicon_db.get_favicon_finish(result)

          if surface
            puts "DEBUG: Got root domain favicon for #{page_uri}"
            save_favicon_data(page_uri, surface)
          else
            puts "DEBUG: No root domain favicon available for #{page_uri}"
          end
        rescue => e
          puts "DEBUG: Error getting root domain favicon: #{e.message}"
        end
      end
    rescue URI::InvalidURIError => e
      puts "DEBUG: Invalid URI for root domain lookup: #{e.message}"
    end
  end

  def save_favicon_data(page_uri, surface)
    favicon_data = surface_to_png(surface)

    if favicon_data
      puts "DEBUG: Saving favicon data (#{favicon_data.bytesize} bytes) for #{page_uri}"
      @history_manager.update_favicon(page_uri, favicon_data)

      # Update the tab's favicon if it matches this URI
      @tabs.each do |tab|
        if tab.uri == page_uri
          tab.favicon_data = favicon_data
        end
      end

      # Refresh tabs to show the new favicon
      refresh_tabs
    else
      puts "DEBUG: Failed to convert favicon to PNG for #{page_uri}"
    end
  end

  def surface_to_png(surface)
    return nil unless surface

    # Create a temporary file to write the PNG
    require 'tempfile'
    temp = Tempfile.new(['favicon', '.png'])
    temp.close

    begin
      # Write surface to PNG file
      surface.write_to_png(temp.path)

      # Read the PNG data
      png_data = File.binread(temp.path)
      png_data
    rescue => e
      warn "Failed to convert favicon: #{e.message}"
      nil
    ensure
      temp.unlink
    end
  end

  def on_back
    current_tab.webview.go_back if current_tab
  end

  def on_forward
    current_tab.webview.go_forward if current_tab
  end

  def create_web_context
    # Set up data directories
    data_dir = File.join(Dir.home, '.local/share/toy-browser')
    cache_dir = File.join(Dir.home, '.cache/toy-browser')

    FileUtils.mkdir_p(data_dir)
    FileUtils.mkdir_p(cache_dir)

    # Get the default web context
    context = WebKit2Gtk::WebContext.default

    # Check what directories the data manager is using
    data_manager = context.website_data_manager
    puts "DEBUG: Base data directory: #{data_manager.base_data_directory}"
    puts "DEBUG: Base cache directory: #{data_manager.base_cache_directory}"
    puts "DEBUG: Local storage directory: #{data_manager.local_storage_directory}"
    puts "DEBUG: IndexedDB directory: #{data_manager.indexeddb_directory}"

    # Set up persistent cookie storage
    cookies_file = File.join(data_dir, 'cookies.sqlite')
    cookie_manager = context.cookie_manager
    cookie_manager.set_persistent_storage(
      cookies_file,
      :sqlite
    )

    # Set up favicon database
    favicon_dir = File.join(data_dir, 'favicons')
    FileUtils.mkdir_p(favicon_dir)
    context.set_favicon_database_directory(favicon_dir)

    context
  end

  def create_sidebar
    sidebar_box = Gtk::Box.new(:vertical, 0)

    # Sidebar header
    @sidebar_header = Gtk::Label.new
    @sidebar_header.markup = "<b>Tabs</b>"
    @sidebar_header.margin_top = 10
    @sidebar_header.margin_bottom = 10
    sidebar_box.pack_start(@sidebar_header, expand: false, fill: false, padding: 0)

    # Scrolled window for list
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)

    # Create both list boxes
    @tabs_list = Gtk::ListBox.new
    @tabs_list.selection_mode = :single
    @tabs_list.signal_connect("row-activated") { |_list, row| on_tab_clicked(row) }

    @history_list = Gtk::ListBox.new
    @history_list.selection_mode = :single
    @history_list.signal_connect("row-activated") { |_list, row| on_history_item_clicked(row) }

    @queue_list = Gtk::ListBox.new
    @queue_list.selection_mode = :single
    @queue_list.signal_connect("row-activated") { |_list, row| on_queue_item_clicked(row) }

    # Container to hold tabs, history, or queue list
    @sidebar_content = Gtk::Box.new(:vertical, 0)
    @sidebar_content.pack_start(@tabs_list, expand: true, fill: true, padding: 0)

    scrolled.add(@sidebar_content)
    sidebar_box.pack_start(scrolled, expand: true, fill: true, padding: 0)

    sidebar_box.set_size_request(300, -1)
    sidebar_box
  end

  def show_tabs_sidebar
    # If already showing tabs sidebar, toggle it off
    if @sidebar_visible && @sidebar_mode == :tabs
      @sidebar.hide
      @paned.set_position(0)
      @sidebar_visible = false
      return
    end

    # Show sidebar if it's hidden
    if !@sidebar_visible
      @sidebar_visible = true
      @sidebar.show_all
      @paned.set_position(@sidebar_width)
    end

    @sidebar_mode = :tabs
    @sidebar_header.markup = "<b>Tabs</b>"

    # Clear sidebar content
    @sidebar_content.children.each { |child| @sidebar_content.remove(child) }

    # Add tabs list
    @sidebar_content.pack_start(@tabs_list, expand: true, fill: true, padding: 0)
    @sidebar_content.show_all

    # Refresh tabs
    refresh_tabs
  end

  def show_history_sidebar
    # If already showing history sidebar, toggle it off
    if @sidebar_visible && @sidebar_mode == :history
      @sidebar.hide
      @paned.set_position(0)
      @sidebar_visible = false
      return
    end

    # Show sidebar if it's hidden
    if !@sidebar_visible
      @sidebar_visible = true
      @sidebar.show_all
      @paned.set_position(@sidebar_width)
    end

    @sidebar_mode = :history
    @sidebar_header.markup = "<b>Browsing History</b>"

    # Clear sidebar content
    @sidebar_content.children.each { |child| @sidebar_content.remove(child) }

    # Add history list
    @sidebar_content.pack_start(@history_list, expand: true, fill: true, padding: 0)
    @sidebar_content.show_all

    # Refresh history
    refresh_history
  end

  def refresh_tabs
    # Clear existing items
    @tabs_list.children.each { |child| @tabs_list.remove(child) }

    # Add a row for each tab
    @tabs.each_with_index do |tab, index|
      row = create_tab_row(tab, index)
      @tabs_list.add(row)

      # Highlight the current tab
      if index == @current_tab_index
        @tabs_list.select_row(row)
      end
    end

    @tabs_list.show_all
  end

  def create_tab_row(tab, index)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = create_favicon_image(tab.favicon_data)
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

    row.add(hbox)

    # Store the tab index in the row
    row.instance_variable_set(:@tab_index, index)

    row
  end

  def on_tab_clicked(row)
    tab_index = row.instance_variable_get(:@tab_index)
    switch_to_tab(tab_index) if tab_index
  end

  def refresh_history
    # Clear existing items
    @history_list.children.each { |child| @history_list.remove(child) }

    # Get recent history
    visits = @history_manager.recent_visits(50)

    visits.each do |visit|
      row = create_history_row(visit)
      @history_list.add(row)
    end

    @history_list.show_all
  end

  def create_history_row(visit)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = create_favicon_image(visit['favicon'])
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = visit['visit_title'] || visit['page_title'] || visit['uri']
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..60])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(visit['uri'])
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Time ago
    time_ago = format_time_ago(visit['visited_at'])
    time_label = Gtk::Label.new(time_ago)
    time_label.halign = :start
    time_label.style_context.add_class("dim-label")
    vbox.pack_start(time_label, expand: false, fill: false, padding: 0)

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    row.add(hbox)

    # Store visit data in the row
    row.instance_variable_set(:@visit_data, visit)

    row
  end

  def on_history_item_clicked(row)
    visit = row.instance_variable_get(:@visit_data)
    if visit && current_tab
      current_tab.webview.load_uri(visit['uri'])
    end
  end

  def show_queue_sidebar
    # If already showing queue sidebar, toggle it off
    if @sidebar_visible && @sidebar_mode == :queue
      @sidebar.hide
      @paned.set_position(0)
      @sidebar_visible = false
      return
    end

    # Show sidebar if it's hidden
    if !@sidebar_visible
      @sidebar_visible = true
      @sidebar.show_all
      @paned.set_position(@sidebar_width)
    end

    @sidebar_mode = :queue
    @sidebar_header.markup = "<b>Queue (#{@queue_manager.count})</b>"

    # Clear sidebar content
    @sidebar_content.children.each { |child| @sidebar_content.remove(child) }

    # Add queue list
    @sidebar_content.pack_start(@queue_list, expand: true, fill: true, padding: 0)
    @sidebar_content.show_all

    # Refresh queue
    refresh_queue
  end

  def refresh_queue
    # Clear existing items
    @queue_list.children.each { |child| @queue_list.remove(child) }

    # Get all queue entries
    entries = @queue_manager.all

    # Get current tab's URL for highlighting
    current_url = current_tab&.webview&.uri

    entries.each do |entry|
      row = create_queue_row(entry)
      @queue_list.add(row)

      # Highlight the queue entry that matches the current tab's URL
      if current_url && entry['url'] == current_url
        @queue_list.select_row(row)
      end
    end

    @queue_list.show_all

    # Update sidebar header with count
    if @sidebar_mode == :queue
      @sidebar_header.markup = "<b>Queue (#{entries.length})</b>"
    end
  end

  def create_queue_row(entry)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content + actions
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = create_favicon_image(entry['favicon'])
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
      refresh_queue
      true  # Stop event propagation
    end
    hbox.pack_start(remove_button, expand: false, fill: false, padding: 0)

    # Wrap in EventBox to enable mouse events for drag-and-drop
    event_box = Gtk::EventBox.new
    event_box.add(hbox)
    event_box.visible_window = false  # Transparent event box

    row.add(event_box)

    # Store entry data in the row and event_box
    row.instance_variable_set(:@queue_entry, entry)
    event_box.instance_variable_set(:@queue_entry, entry)
    event_box.instance_variable_set(:@parent_row, row)

    # Set up drag-and-drop for reordering on the event_box
    setup_queue_row_drag_and_drop(event_box)

    row
  end

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
    widget.drag_dest_set(
      Gtk::DestDefaults::MOTION | Gtk::DestDefaults::HIGHLIGHT,
      [target_entry],
      Gdk::DragAction::MOVE
    )

    # Store reference to browser window
    browser_window = self

    # Handle drag data get (provide the data when dragging)
    widget.signal_connect("drag-data-get") do |w, context, selection_data, info, time|
      entry = w.instance_variable_get(:@queue_entry)
      if entry
        # Send the entry ID as plain text
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
        dropped_entry_id = dropped_id_text.to_i
        target_entry = w.instance_variable_get(:@queue_entry)

        if target_entry && dropped_entry_id != target_entry['id']
          # Move the dropped entry to the target position
          if browser_window.queue_manager.move(dropped_entry_id, target_entry['position'])
            # Refresh the queue to show the new order
            browser_window.refresh_queue

            # Find and select the moved row
            browser_window.queue_list.children.each do |child|
              child_entry = child.instance_variable_get(:@queue_entry)
              if child_entry && child_entry['id'] == dropped_entry_id
                browser_window.queue_list.select_row(child)
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

  # Expose queue_manager and queue_list for drag-and-drop callbacks
  attr_reader :queue_manager, :queue_list

  def on_queue_item_clicked(row)
    entry = row.instance_variable_get(:@queue_entry)
    if entry && current_tab
      current_tab.webview.load_uri(entry['url'])
    end
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
      if @sidebar_mode == :queue
        refresh_queue
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
    if @sidebar_mode == :queue
      refresh_queue
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
    return unless @sidebar_mode == :queue

    # Get the currently selected row
    selected_row = @queue_list.selected_row
    return unless selected_row

    # Get the entry data
    entry = selected_row.instance_variable_get(:@queue_entry)
    return unless entry

    # Move up in the queue
    if @queue_manager.move_up(entry['id'])
      # Refresh the queue
      refresh_queue

      # Find and select the row that now contains this entry
      @queue_list.children.each do |row|
        row_entry = row.instance_variable_get(:@queue_entry)
        if row_entry && row_entry['id'] == entry['id']
          @queue_list.select_row(row)
          break
        end
      end

      puts "Moved up: #{entry['title'] || entry['url']}"
    end
  end

  def move_selected_queue_entry_down
    # Only works when queue sidebar is visible
    return unless @sidebar_mode == :queue

    # Get the currently selected row
    selected_row = @queue_list.selected_row
    return unless selected_row

    # Get the entry data
    entry = selected_row.instance_variable_get(:@queue_entry)
    return unless entry

    # Move down in the queue
    if @queue_manager.move_down(entry['id'])
      # Refresh the queue
      refresh_queue

      # Find and select the row that now contains this entry
      @queue_list.children.each do |row|
        row_entry = row.instance_variable_get(:@queue_entry)
        if row_entry && row_entry['id'] == entry['id']
          @queue_list.select_row(row)
          break
        end
      end

      puts "Moved down: #{entry['title'] || entry['url']}"
    end
  end

  def navigate_to_next_queue_item
    # Only works when queue sidebar is visible
    return unless @sidebar_mode == :queue && current_tab

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
    return unless @sidebar_mode == :queue && current_tab

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
    return unless @sidebar_mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Find the current URL in the queue
    entry = @queue_manager.find_by_url(current_url)
    return unless entry

    # Move up in the queue
    if @queue_manager.move_up(entry['id'])
      refresh_queue
      puts "Moved current page up in queue: #{entry['title'] || entry['url']}"
    end
  end

  def move_current_page_down_in_queue
    # Only works when queue sidebar is visible
    return unless @sidebar_mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    # Find the current URL in the queue
    entry = @queue_manager.find_by_url(current_url)
    return unless entry

    # Move down in the queue
    if @queue_manager.move_down(entry['id'])
      refresh_queue
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

  def format_time_ago(timestamp)
    seconds_ago = Time.now.to_i - timestamp
    minutes_ago = seconds_ago / 60
    hours_ago = minutes_ago / 60
    days_ago = hours_ago / 24

    if seconds_ago < 60
      "Just now"
    elsif minutes_ago < 60
      "#{minutes_ago}m ago"
    elsif hours_ago < 24
      "#{hours_ago}h ago"
    elsif days_ago == 1
      "Yesterday"
    else
      "#{days_ago} days ago"
    end
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
          fetch_and_save_favicon(uri)
        end
      end
    end
  end

  def toggle_sidebar
    if @sidebar_visible
      # Hide sidebar - set flag BEFORE changing position
      @sidebar_visible = false
      @sidebar.hide
      @paned.set_position(0)
    else
      # Show sidebar
      @sidebar.show_all
      @paned.set_position(@sidebar_width)
      @sidebar_visible = true
    end
  end

  def toggle_zen_mode
    if @zen_mode
      # Exit zen mode - show toolbar and restore sidebar state
      @toolbar.show_all
      if @sidebar_visible_before_zen
        @sidebar.show_all
        @paned.set_position(@sidebar_width)
        @sidebar_visible = true
      end
      @zen_mode = false
    else
      # Enter zen mode - hide toolbar and sidebar
      @sidebar_visible_before_zen = @sidebar_visible
      @toolbar.hide

      if @sidebar_visible
        @sidebar.hide
        @paned.set_position(0)
        @sidebar_visible = false
      end

      @zen_mode = true
    end
  end

  def toggle_dark_mode
    @dark_mode = !@dark_mode

    # Toggle GTK theme variant (affects browser UI)
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # Save settings
    save_settings

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

  def load_settings
    settings_file = File.join(@data_dir, 'settings.json')

    # Default settings
    @dark_mode = false
    @sidebar_width_ratio = 0.25  # 25% of window width

    if File.exist?(settings_file)
      begin
        settings = JSON.parse(File.read(settings_file))
        @dark_mode = settings['dark_mode'] || false
        @sidebar_width_ratio = settings['sidebar_width_ratio'] || 0.25
        puts "DEBUG: Loaded sidebar width ratio from settings: #{@sidebar_width_ratio}"
      rescue => e
        puts "Failed to load settings: #{e.message}"
      end
    else
      puts "DEBUG: No settings file, using default ratio: #{@sidebar_width_ratio}"
    end
  end

  def save_settings
    settings_file = File.join(@data_dir, 'settings.json')

    # Calculate ratio based on current window width
    window_width = allocation.width
    if window_width > 0 && @sidebar_visible
      @sidebar_width_ratio = @sidebar_width.to_f / window_width.to_f
      @sidebar_width_ratio = [@sidebar_width_ratio, 0.1].max  # Min 10%
      @sidebar_width_ratio = [@sidebar_width_ratio, 0.5].min  # Max 50%
    end

    settings = {
      'dark_mode' => @dark_mode,
      'sidebar_width_ratio' => @sidebar_width_ratio
    }

    begin
      File.write(settings_file, JSON.pretty_generate(settings))
      puts "DEBUG: Saved sidebar width ratio: #{@sidebar_width_ratio}"
    rescue => e
      puts "Failed to save settings: #{e.message}"
    end
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
    save_session

    # Spawn a new browser process with the same script
    script_path = File.expand_path($PROGRAM_NAME)
    spawn("ruby", script_path)

    # Close this window (will quit the application)
    close
  end

  # Background worker loop for fetching queue entry metadata
  def favicon_worker_loop
    while @favicon_worker_running
      item = @favicon_fetch_queue.pop
      break if item.nil?  # Poison pill to stop worker

      begin
        fetch_queue_entry_metadata(item[:id], item[:url])
      rescue => e
        warn "Error fetching metadata for #{item[:url]}: #{e.message}"
      end
    end
  end

  # Fetch title and favicon for a queue entry
  def fetch_queue_entry_metadata(entry_id, url)
    uri = URI.parse(url)

    # Fetch the page
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                               open_timeout: 5, read_timeout: 5) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
      http.request(request)
    end

    return unless response.is_a?(Net::HTTPSuccess)

    html = response.body
    title = extract_title_from_html(html)
    favicon_url = extract_favicon_url_from_html(html, uri)

    # Fetch favicon if found
    favicon_data = nil
    if favicon_url
      favicon_data = fetch_favicon(favicon_url)
    else
      # Try default /favicon.ico
      default_favicon_url = "#{uri.scheme}://#{uri.host}/favicon.ico"
      favicon_data = fetch_favicon(default_favicon_url)
    end

    # Update database (safe to do from background thread)
    @queue_manager.update_title(url, title) if title
    @queue_manager.update_favicon(url, favicon_data) if favicon_data

    # Schedule UI refresh on main thread
    GLib::Idle.add do
      refresh_queue if @sidebar_mode == :queue
      false  # Don't repeat
    end
  end

  def extract_title_from_html(html)
    # Simple regex to extract title
    match = html.match(/<title[^>]*>(.*?)<\/title>/im)
    return nil unless match

    title = match[1].strip

    # Ensure UTF-8 encoding, replacing invalid characters
    title = title.force_encoding('UTF-8')
    unless title.valid_encoding?
      # Try different encodings
      title = title.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    CGI.unescapeHTML(title)
  end

  def extract_favicon_url_from_html(html, base_uri)
    # Look for <link rel="icon"> or <link rel="shortcut icon">
    match = html.match(/<link[^>]*rel=["'](?:shortcut )?icon["'][^>]*href=["']([^"']+)["']/im)
    return nil unless match

    favicon_path = match[1]

    # Make absolute URL if relative
    if favicon_path.start_with?('http')
      favicon_path
    elsif favicon_path.start_with?('//')
      "#{base_uri.scheme}:#{favicon_path}"
    elsif favicon_path.start_with?('/')
      "#{base_uri.scheme}://#{base_uri.host}#{favicon_path}"
    else
      "#{base_uri.scheme}://#{base_uri.host}/#{favicon_path}"
    end
  end

  def fetch_favicon(favicon_url)
    uri = URI.parse(favicon_url)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                               open_timeout: 3, read_timeout: 3) do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request)
    end

    return response.body if response.is_a?(Net::HTTPSuccess)
    nil
  rescue => e
    # Silently fail for favicons
    nil
  end

  def save_session
    session_file = File.join(@data_dir, 'session.json')

    # Collect all tab URLs
    tab_urls = @tabs.map { |tab| tab.uri || "https://www.google.com" }

    session = {
      'tabs' => tab_urls,
      'current_tab_index' => @current_tab_index
    }

    begin
      File.write(session_file, JSON.pretty_generate(session))
    rescue => e
      puts "Failed to save session: #{e.message}"
    end
  end

  def load_session
    session_file = File.join(@data_dir, 'session.json')

    if File.exist?(session_file)
      begin
        session = JSON.parse(File.read(session_file))

        # Delete session file after loading
        File.delete(session_file)

        return session
      rescue => e
        puts "Failed to load session: #{e.message}"
      end
    end

    nil
  end
end

# Main application
app = Gtk::Application.new("com.example.browser", :flags_none)

app.signal_connect "activate" do |application|
  win = BrowserWindow.new
  win.set_application(application)
  win.show_all
end

app.run
