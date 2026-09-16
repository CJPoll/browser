# BrowserWindow - Main browser window orchestrator
#
# This class coordinates all browser components (UI, handlers, managers) and sets up
# GTK signal handlers. It acts as a thin orchestration layer with minimal business logic.
#
# Responsibilities:
# - Component initialization and lifecycle management
# - GTK event handler setup (keyboard, mouse, webview signals)
# - Callback wiring between components
# - Tab management coordination
# - Window state (zen mode, dark mode)
#
# The window delegates business logic to specialized components:
# - Navigation: NavigationHandler
# - Keyboard: KeyboardHandler
# - Mouse: MouseHandler
# - Favicon: FaviconManager
# - Settings: Managers::SettingsManager
# - Session: Managers::SessionManager
# - Queue metadata: QueueMetadataWorker

require 'gtk3'
require 'webkit2-gtk'
require 'json'
require 'fileutils'
require_relative 'ui/find_bar'
require_relative 'ui/reader_view'
require_relative 'ui/download_list_view'
require_relative 'ui/download_notification_bar'
require_relative 'ui/certificate_exception_bar'
require_relative 'ui/notification_permission_bar'
require_relative 'ui/passkey_prompt_bar'
require_relative 'ui/site_permissions_window'
require_relative 'ui/autocomplete_popover'
require_relative 'ui/file_chooser'
require_relative 'ui/video_popout_window'
require_relative 'domain/crash_page'
require_relative 'domain/media_permission_type'
require_relative 'domain/url_classifier'
require_relative 'domain/article_extractor_js'
require_relative 'domain/file_filters'
require_relative 'domain/chrome_visibility'
require_relative 'managers/site_permission_manager'
require_relative 'managers/popup_manager'
require_relative 'managers/permission_request_manager'
require_relative 'managers/web_notification_dispatcher'
require_relative 'managers/history_manager'
require_relative 'managers/autocomplete_manager'
require_relative 'managers/download_coordinator'
require_relative 'managers/queue_manager'
require_relative 'managers/queue_navigation_manager'
require_relative 'managers/queue_metadata_worker'
require_relative 'managers/session_manager'
require_relative 'managers/settings_manager'
require_relative 'managers/external_opener'
require_relative 'managers/browser_restarter'
require_relative 'managers/pdf_bookmark_manager'
require_relative 'handlers/download_handler'
require_relative 'handlers/markdown_handler'
require_relative 'handlers/passkey_handler'

class BrowserWindow < Gtk::Window
  def initialize
    super

    set_title("Toy Browser")
    set_default_size(1200, 768)

    # === Data Storage ===
    @data_dir = File.join(Dir.home, '.local/share/toy-browser')
    FileUtils.mkdir_p(@data_dir)

    # === Core Managers ===
    @history_manager = Managers::HistoryManager.new
    @queue_manager = Managers::QueueManager.new
    @queue_navigation_manager = Managers::QueueNavigationManager.new(@queue_manager)
    @download_coordinator = DownloadCoordinator.new
    @site_permission_manager = Managers::SitePermissionManager.new
    @popup_manager = Managers::PopupManager.new(site_permissions: @site_permission_manager)
    @permission_request_manager = Managers::PermissionRequestManager.new(
      site_permissions: @site_permission_manager
    )
    @web_notification_dispatcher = Managers::WebNotificationDispatcher.new
    @settings_manager = Managers::SettingsManager.new
    @session_manager = Managers::SessionManager.new
    @external_opener = Managers::ExternalOpener.new
    @browser_restarter = Managers::BrowserRestarter.new(session_manager: @session_manager)
    @pdf_bookmark_manager = Managers::PdfBookmarkManager.new

    # Passkeys: the browser is the WebAuthn authenticator (WebKitGTK has none).
    # The handler injects navigator.credentials into every tab and asks this
    # window to show the consent bar.
    @passkey_handler = PasskeyHandler.new(
      { show_prompt: ->(prompt, on_allow:, on_cancel:) { show_passkey_prompt_bar(prompt, on_allow: on_allow, on_cancel: on_cancel) } }
    )

    # === Background Workers ===
    @queue_metadata_worker = Managers::QueueMetadataWorker.new(@queue_manager)
    @queue_metadata_worker.on_metadata_fetched = -> {
      @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue
    }

    # === Settings State ===
    @dark_mode = @settings_manager.dark_mode

    # Apply dark mode setting to GTK
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # === Chrome Visibility State ===
    # Chrome (toolbar + sidebar) hides for two independent reasons -- zen mode
    # (F11) and video fullscreen (per-tab, on Tab#fullscreen). Both funnel
    # through apply_chrome_visibility / Domain::ChromeVisibility so overlaps
    # compose. This flag remembers whether the sidebar was visible when the
    # chrome was hidden, so showing it again is a temporary override rather
    # than a change to the user's sidebar preference.
    @zen_mode = false
    @sidebar_visible_before_chrome_hidden = false

    # === Popup Notification Tracking ===
    # Track hosts with active notifications to avoid duplicates
    @popup_notification_hosts = Set.new

    # === In-flight Permission Requests ===
    # Site permissions themselves live in @site_permission_manager; these track
    # which requests already have a bar on screen, so a repeat request from the
    # same host does not stack a second one.
    @media_permission_pending = {}  # Pending requests by "host:permission_type"
    @certificate_exception_pending = Set.new  # Hosts with an active certificate bar
    @notification_permission_pending = Set.new  # Hosts with an active notification bar

    # === Tab Management ===
    @tabs = []
    @current_tab_index = 0

    # === WebKit Context ===
    # Create web context first (needed for tabs)
    @web_context = WebContextManager.create(data_dir: @data_dir)

    # Handle downloads from web context
    @download_handler = DownloadHandler.new(
      @web_context,
      @download_coordinator,
      on_download_started: ->(download) { on_download_started(download) },
      on_download_progress: ->(download) { on_download_progress(download) },
      on_download_finished: ->(download) { on_download_finished(download) },
      on_download_failed: ->(download) { on_download_failed(download) }
    )

    # Discard download records past their retention period. Records only --
    # the downloaded files themselves are never touched.
    GLib::Timeout.add_seconds(DownloadCoordinator::CLEANUP_INTERVAL_SECONDS) do
      @download_coordinator.cleanup_old_downloads
      true # Keep repeating
    end

    # Create layout
    vbox = ::Gtk::Box.new(:vertical, 0)
    add(vbox)

    # Toolbar
    toolbar_callbacks = {
      on_sidebar_toggle: -> { toggle_sidebar },
      on_back: -> { on_back },
      on_forward: -> { on_forward },
      on_load_url: -> { @navigation_handler.navigate_to(@url_entry.text) },
      on_reader_toggle: -> { toggle_reader_mode },
      on_downloads_toggle: -> { show_downloads_sidebar },
      get_current_tab: -> { current_tab },  # Safe: nil during init, but callbacks only fire during user interaction
      in_zen_mode: -> { @zen_mode },
      get_download_state: -> { @download_coordinator.badge_state },
      on_toggle_dark_mode: -> { toggle_dark_mode },
      get_dark_mode: -> { @dark_mode }
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

    # Markdown handler for .md file rendering
    @markdown_handler = MarkdownHandler.new

    # Mouse handler
    mouse_callbacks = {
      get_current_tab: -> { current_tab },
      create_new_tab: ->(uri, switch_to:) { create_new_tab(uri, switch_to: switch_to) },
      handle_markdown_navigation: ->(webview, uri) { @markdown_handler.handle_navigation(webview, uri) }
    }
    @mouse_handler = MouseHandler.new(mouse_callbacks)

    # === Autocomplete Setup ===
    # Create autocomplete manager for URL suggestions
    @autocomplete_manager = AutocompleteManager.new(@history_manager)

    # Create autocomplete popover attached to URL entry
    autocomplete_callbacks = {
      on_select: ->(uri) {
        @url_entry.text = uri
        @autocomplete_popover.hide
        @navigation_handler.navigate_to(uri)
      },
      create_favicon_image: ->(data) { create_favicon_image(data) }
    }
    @autocomplete_popover = AutocompletePopover.new(@url_entry, autocomplete_callbacks)

    # Wire toolbar autocomplete callback and popover reference
    @toolbar_component.on_autocomplete = ->(query) {
      handle_autocomplete(query)
    }
    @toolbar_component.autocomplete_popover = @autocomplete_popover

    # Pack toolbar into main layout
    vbox.pack_start(@toolbar, expand: false, fill: false, padding: 0)

    # Keep @toolbar and @url_entry references for:
    # - Zen mode operations (lines 1209, 1219)
    # - URL updates on navigation (line 757)

    # Horizontal paned for sidebar and content
    @paned = Gtk::Paned.new(:horizontal)
    @paned.wide_handle = true  # Make the resize handle more visible
    vbox.pack_start(@paned, expand: true, fill: true, padding: 0)

    # Find bar (hidden by default, shown with Ctrl+F)
    find_bar_callbacks = {
      on_close: -> { @find_bar.hide },
      get_current_tab: -> { current_tab }
    }
    @find_bar = FindBar.new(find_bar_callbacks)
    @find_bar.widget.no_show_all = true  # Prevent show_all from showing this widget
    @find_bar.widget.hide  # Hidden by default
    vbox.pack_end(@find_bar.widget, expand: false, fill: false, padding: 0)

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
    tab_list_view.on_tab_reordered = ->(from_index, to_index) { move_tab(from_index, to_index) }
    tab_list_view.on_tab_closed = ->(index) { close_tab_at_index(index) }

    # The list views render history and the queue and report intent; this
    # window binds each data source and each intent to a manager.
    history_list_view = HistoryListView.new(
      create_favicon_image: ->(favicon_data) { create_favicon_image(favicon_data) },
      get_search_results: ->(query, limit) { @history_manager.search(query, limit) },
      get_recent_visits: ->(limit) { @history_manager.recent_visits(limit) },
      on_delete_visit: ->(visit_id) { @history_manager.delete_visit(visit_id) }
    )
    history_list_view.on_history_item_selected = ->(visit) {
      current_tab.webview.load_uri(visit.uri) if current_tab
    }

    queue_list_view = QueueListView.new(
      create_favicon_image: ->(favicon_data) { create_favicon_image(favicon_data) },
      get_entries: ->(tag_ids) { @queue_manager.entries_for_filter(tag_ids) },
      get_total_count: -> { @queue_manager.count },
      get_tags_for_entry: ->(entry_id) { @queue_manager.tags_for_entry(entry_id) },
      get_tag_usages: -> { @queue_manager.tag_usage_counts },
      find_tag_by_name: ->(tag_name) { @queue_manager.find_tag_by_name(tag_name) },
      find_tag_by_id: ->(tag_id) { @queue_manager.find_tag_by_id(tag_id) },
      on_remove_entry: ->(entry_id) { @queue_manager.remove_by_id(entry_id) },
      on_move_entry: ->(entry_id, position) { @queue_manager.move(entry_id, position) }
    )
    queue_list_view.on_queue_item_selected = ->(entry) {
      current_tab.webview.load_uri(entry.url) if current_tab
    }

    queue_list_view.on_queue_entry_right_click = ->(entry, event) {
      show_queue_entry_context_menu(entry, event)
    }

    # The view renders downloads and reports intent; this window binds each
    # intent to the coordinator or the download handler.
    @download_list_view = DownloadListView.new(
      get_downloads: -> { @download_coordinator.get_all_downloads },
      on_pause: ->(download_id) { @download_handler.pause(download_id); update_download_badge },
      on_resume: ->(download_id) { @download_handler.resume(download_id); update_download_badge },
      on_cancel: ->(download_id) { @download_handler.cancel(download_id); update_download_badge },
      on_remove: ->(download_id) { @download_coordinator.delete_download(download_id); update_download_badge },
      on_open_location: ->(destination) {
        # Open file manager at the download location
        @external_opener.open_containing_directory(destination)
      }
    )

    # Create sidebar component
    sidebar_callbacks = {
      get_tabs: -> { [@tabs, @current_tab_index] },
      get_current_tab: -> { current_tab },
      get_queue_count: -> { @queue_manager.count },
      get_download_count: -> { @download_coordinator.download_count },
      get_paned: -> { @paned }
    }
    @sidebar_component = Sidebar.new(
      { tab_list_view: tab_list_view, history_list_view: history_list_view, queue_list_view: queue_list_view, download_list_view: @download_list_view },
      sidebar_callbacks
    )

    # Wire queue callback AFTER sidebar creation (safe because queue isn't modified during init)
    queue_list_view.on_queue_modified = ->(filtered_count, total_count) {
      @sidebar_component.update_queue_header(filtered_count, total_count)
      @sidebar_component.update_filter_bar(
        queue_list_view.active_filter_tag_names,
        queue_list_view
      )
    }

    # Callback to get current URL for filter refresh
    queue_list_view.on_get_current_url = -> {
      current_tab&.webview&.uri
    }

    # Callback when filter state changes
    queue_list_view.on_filter_state_changed = ->(active) {
      @sidebar_component.update_filter_button_state(active)
    }

    # Default to showing queue view
    @sidebar_component.show_queue

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
        # Start the sidebar at the narrowest width its contents fit in, measured
        # now that the real queue is loaded and GTK has done layout
        sidebar_width = @sidebar_component.minimum_content_width
        @sidebar_component.update_width(sidebar_width)
        @paned.set_position(sidebar_width)
        @paned_position_set = true
        @initial_map_done = true
      end
      false
    end

    # Save settings when window is closing
    signal_connect("delete-event") do
      @settings_manager.save
      false  # Allow the window to close
    end

    # Set up favicon database

    # Set up favicon database and manager
    begin
      @favicon_db = @web_context.favicon_database

      # Create favicon manager
      @favicon_manager = FaviconManager.new(@favicon_db, @history_manager, -> { @tabs })
      @favicon_manager.on_favicon_updated = -> { @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs }
    rescue => e
      @favicon_db = nil
      @favicon_manager = nil
    end

    # Right side content area (notification bar + webview)
    @content_vbox = Gtk::Box.new(:vertical, 0)
    @paned.pack2(@content_vbox, resize: true, shrink: false)

    # Overlay for layering reader view on top of webview
    @content_overlay = Gtk::Overlay.new
    @content_vbox.pack_start(@content_overlay, expand: true, fill: true, padding: 0)

    # Scrolled window for webview (will swap webviews when switching tabs)
    @webview_container = Gtk::ScrolledWindow.new
    @content_overlay.add(@webview_container)

    # Reader view (overlay on top of webview)
    reader_callbacks = {
      on_close: -> { @reader_view_active = false }
    }
    @reader_view = ReaderView.new(reader_callbacks)
    @reader_view_active = false
    @content_overlay.add_overlay(@reader_view.widget)

    # Restore session if available, otherwise create initial tab
    # Command-line URLs are handled by BrowserApplication after window creation
    session = @session_manager.restore
    if session
      # Restore tabs from session
      session.tab_urls.each do |tab_url|
        create_new_tab(tab_url)
      end

      # Restore the tab the user was on
      switch_to_tab(session.current_tab_index)
    else
      # Create initial tab
      create_new_tab("https://www.example.com")
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
      # Stop the background workers
      @queue_metadata_worker.stop

      # Save session and settings
      save_current_session
      @settings_manager.save
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
        show_downloads: -> { show_downloads_sidebar },
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
        move_current_down: -> { move_current_page_down_in_queue },
        find_queue_entry_by_url: ->(url) { @queue_manager.find_by_url(url) },
        show_tag_edit_dialog: ->(entry) { show_tag_edit_dialog(entry) }
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
        open_video_popout: -> { open_video_popout },
        open_site_permissions: -> { open_site_permissions },
        open_file: -> { open_file },
        print_page: -> { print_page }
      },
      find_actions: {
        show_find_bar: -> { @find_bar.show }
      },
      markdown_actions: {
        toggle_source: -> { toggle_markdown_source },
        add_pdf_bookmarks: -> { add_pdf_bookmarks }
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

  # ========================================
  # Tab Management
  # ========================================

  def current_tab
    return nil if @tabs.empty?
    @tabs[@current_tab_index]
  end

  # The URI the window's first tab is showing
  #
  # The application asks so it can decide whether a URL arriving from another
  # instance should replace the window's untouched first page or open a tab of
  # its own.
  #
  # @return [String, nil] URI of the first tab, if it has one
  def first_tab_uri
    @tabs.first&.uri
  end

  # Points the first tab at a URL
  #
  # @param url [String] URL to load
  # @return [void]
  def load_url_in_first_tab(url)
    @tabs.first&.webview&.load_uri(url)
  end

  def create_new_tab(uri = "https://www.google.com", switch_to: true)
    # Create tab WITHOUT loading URI (Tab no longer auto-loads)
    tab = Tab.new(@web_context, @favicon_db, uri)

    # Connect signals for this tab BEFORE loading URI
    # This ensures decide-policy handler can intercept markdown files
    setup_tab_signals(tab)

    @tabs << tab

    # Switch to the new tab if requested
    if switch_to
      @current_tab_index = @tabs.length - 1
      switch_to_tab(@current_tab_index)
    end

    # NOW load the URI (after decide-policy handler is connected)
    tab.load_uri(uri)

    # Refresh tabs sidebar
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs
  end

  def close_current_tab
    close_tab_at_index(@current_tab_index)
  end

  # Closes the tab at the specified index
  #
  # @param index [Integer] Index of the tab to close
  # @return [void]
  def close_tab_at_index(index)
    return if @tabs.empty?
    return if index < 0 || index >= @tabs.length

    # Get the tab to close
    tab_to_close = @tabs[index]

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
      end
    end

    # Remove the tab
    @tabs.delete_at(index)

    # If that was the last tab, create a new one
    if @tabs.empty?
      create_new_tab
      return
    end

    # Adjust current_tab_index if needed
    if index < @current_tab_index
      # Closed a tab before current - shift index down
      @current_tab_index -= 1
    elsif index == @current_tab_index
      # Closed the current tab - stay at same index or move to last
      if @current_tab_index >= @tabs.length
        @current_tab_index = @tabs.length - 1
      end
      # Switch to the new current tab
      switch_to_tab(@current_tab_index)
    end
    # If closed tab after current, no adjustment needed

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

  # Moves a tab from one position to another (for drag-and-drop reordering)
  #
  # @param from_index [Integer] Source index of the tab
  # @param to_index [Integer] Destination index
  # @return [Boolean] True if move succeeded
  def move_tab(from_index, to_index)
    return false if from_index < 0 || from_index >= @tabs.length
    return false if to_index < 0 || to_index >= @tabs.length
    return false if from_index == to_index

    # Remove the tab from its current position
    tab = @tabs.delete_at(from_index)

    # Insert at the new position
    @tabs.insert(to_index, tab)

    # Update current_tab_index to follow the current tab
    if @current_tab_index == from_index
      # We moved the current tab
      @current_tab_index = to_index
    elsif from_index < @current_tab_index && to_index >= @current_tab_index
      # Tab moved from before current to after (or at) current
      @current_tab_index -= 1
    elsif from_index > @current_tab_index && to_index <= @current_tab_index
      # Tab moved from after current to before (or at) current
      @current_tab_index += 1
    end

    # Refresh tabs sidebar to show new order
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :tabs

    true
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

    # The new tab may differ in fullscreen state from the old one; reconcile.
    apply_chrome_visibility
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

    # Handle TLS certificate errors (self-signed certs, etc.)
    tab.webview.signal_connect("load-failed-with-tls-errors") do |_webview, failing_uri, certificate, _errors|
      decision = @permission_request_manager.certificate_request(failing_uri)

      case decision.action
      when :allow
        # Already trusted: accept the certificate and load the page
        @web_context.allow_tls_certificate_for_host(certificate, decision.host)
        tab.webview.load_uri(failing_uri)
      when :prompt
        show_certificate_exception_bar(decision.host, failing_uri, certificate, tab)
      end

      true  # We handled it, don't emit load-failed
    end

    # The process rendering this tab died: WebKit leaves the tab blank, so say
    # what happened instead of losing the page silently
    tab.webview.signal_connect("web-process-terminated") do |_webview, reason|
      on_web_process_terminated(tab, reason)
    end

    # A video entered/left Fullscreen API fullscreen. Hide/restore the chrome
    # so the video fills the window. Return false so WebKit still performs its
    # own native fullscreen; returning true would cancel it. Both exit paths
    # (Esc and the in-player control) funnel through leave-fullscreen.
    tab.webview.signal_connect("enter-fullscreen") do
      tab.fullscreen = true
      apply_chrome_visibility if current_tab == tab
      false
    end

    tab.webview.signal_connect("leave-fullscreen") do
      tab.fullscreen = false
      apply_chrome_visibility if current_tab == tab
      false
    end

    # Handle mouse button events on the WebView
    tab.webview.signal_connect("button-press-event") do |_webview, event|
      next false unless current_tab == tab
      @mouse_handler.handle_button_press(tab.webview, event)
    end

    # Handle key events on the WebView (for shortcuts that WebKit might intercept)
    tab.webview.signal_connect("key-press-event") do |_webview, event|
      next false unless current_tab == tab

      # Ctrl+U: Toggle markdown source view (intercept before WebKit's "View Source")
      if event.state.control_mask? && !event.state.shift_mask? && !event.state.mod1_mask?
        if event.keyval == Gdk::Keyval::KEY_u
          toggle_markdown_source
          next true  # Event handled, stop propagation
        end
      end

      false  # Let other handlers process
    end

    # Handle Ctrl+Click to open links in new tab
    tab.webview.signal_connect("decide-policy") do |_webview, decision, decision_type|
      @mouse_handler.handle_decide_policy(tab.webview, decision, decision_type, tab)
    end

    # Handle context menu to add custom options for links and pages
    tab.webview.signal_connect("context-menu") do |_webview, context_menu, event, hit_test_result|
      # Check if we right-clicked on a link
      if hit_test_result.link_uri
        link_uri = hit_test_result.link_uri

        # Remove "Open Link" (WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK) from default menu
        items_to_remove = []
        context_menu.items.each_with_index do |item, index|
          # WebKit's "Open Link" action has stock action OPEN_LINK (1)
          if item.stock_action == WebKit2Gtk::ContextMenuAction::OPEN_LINK
            items_to_remove << index
          end
        end
        # Remove items in reverse order to maintain correct indices
        items_to_remove.reverse.each { |index| context_menu.remove(context_menu.items[index]) }

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
              @queue_metadata_worker.enqueue(entry.id, link_uri)
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
        context_menu.insert(open_tab_item, 1)  # Insert at position 1 (after "Add to Queue")

        # Add separator after our custom items and "Open Link in New Window"
        separator = WebKit2Gtk::ContextMenuItem.new()
        context_menu.insert(separator, 3)  # Position 3 (after Add to Queue, Open in New Tab, Open in New Window)
      else
        # Right-clicked on page (not a link) - add queue option for current page
        page_uri = tab.webview.uri
        if page_uri && !page_uri.empty? && page_uri != "about:blank"
          # Check if current page is already in queue
          existing_entry = @queue_manager.find_by_url_fuzzy(page_uri)

          if existing_entry
            # Page is in queue - show "Remove from Queue"
            remove_action = Gio::SimpleAction.new("remove-page-from-queue-#{page_uri.hash.abs}", nil)
            remove_action.signal_connect("activate") do
              @queue_manager.remove_by_url(page_uri)
              puts "Removed from queue: #{page_uri}"
              @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue
            end

            remove_item = WebKit2Gtk::ContextMenuItem.new(remove_action, "Remove from Queue", nil)
            context_menu.prepend(remove_item)
          else
            # Page is not in queue - show "Add to Queue"
            add_action = Gio::SimpleAction.new("add-page-to-queue-#{page_uri.hash.abs}", nil)
            add_action.signal_connect("activate") do
              page_title = tab.webview.title
              page_favicon = tab.favicon_data

              result = @queue_manager.add(page_uri, page_title, page_favicon)
              case result
              when :added
                puts "Added to queue: #{page_uri}"
                @sidebar_component.refresh_current_view if @sidebar_component.mode == :queue
              when :already_exists
                puts "Already in queue: #{page_uri}"
              when :invalid_url
                warn "Cannot add invalid URL to queue"
              end
            end

            add_item = WebKit2Gtk::ContextMenuItem.new(add_action, "Add to Queue", nil)
            context_menu.prepend(add_item)
          end

          # Add separator after our custom item
          separator = WebKit2Gtk::ContextMenuItem.new()
          context_menu.insert(separator, 1)
        end
      end

      false  # Let the default menu show
    end

    # Handle popup requests (window.open, target="_blank", etc.)
    tab.webview.signal_connect("create") do |_webview, navigation_action|
      destination_url = navigation_action.request&.uri

      open_requested_popup(@popup_manager.request(destination_url), tab.webview)
    end

    # Handle media permission requests (camera/microphone) and notification permissions
    tab.webview.signal_connect("permission-request") do |webview, request|
      handle_permission_request(webview, request)
    end

    # Handle web notifications - send to dunst via notify-send
    tab.webview.signal_connect("show-notification") do |webview, notification|
      handle_web_notification(webview, notification)
    end

    # Handle permission state queries (for Notification.permission checks)
    tab.webview.signal_connect("query-permission-state") do |webview, query|
      handle_permission_state_query(webview, query)
    end

    # Handle file chooser requests with image preview
    tab.webview.signal_connect("run-file-chooser") do |webview, request|
      handle_file_chooser_request(webview, request)
    end

    # Give the page navigator.credentials, answered by the passkey handler
    @passkey_handler.attach(tab.webview)
  end

  # Opens (or blocks) a popup the page asked for
  #
  # @param decision [Domain::PopupDecision] What Managers::PopupManager decided
  # @param related_view [WebKit2Gtk::WebView] WebView the popup belongs to
  # @return [WebKit2Gtk::WebView, nil] The webview WebKit should load the
  #   popup into, or nil when the popup is not being opened here
  def open_requested_popup(decision, related_view)
    case decision.action
    when :oauth_window
      popup = PopupWindow.new(related_view, self)
      puts "OAuth popup opened: #{decision.url}"
      popup.webview
    when :new_tab
      create_new_tab(decision.url, switch_to: true)
      puts "Popup opened in new tab: #{decision.url}"
      nil  # We handled it ourselves
    when :prompt
      show_popup_blocked_notification(decision.host, decision.url, related_view)
      puts "Popup blocked from: #{decision.host}"
      nil  # Block the popup
    end
  end

  # Handles permission requests (media and notification)
  #
  # @param webview [WebKit2Gtk::WebView] The webview making the request
  # @param request [WebKit2Gtk::PermissionRequest] The permission request
  # @return [Boolean] True to stop signal propagation
  def handle_permission_request(webview, request)
    if request.is_a?(WebKit2Gtk::NotificationPermissionRequest)
      return handle_notification_permission_request(webview, request)
    end

    return false unless request.is_a?(WebKit2Gtk::UserMediaPermissionRequest)

    permission_type = Domain::MediaPermissionType.for(
      audio: request.is_for_audio_device?,
      video: request.is_for_video_device?
    )
    decision = @permission_request_manager.media_request(webview.uri, permission_type)

    case decision.action
    when :allow
      request.allow
      puts "Media permission auto-allowed for #{decision.host} (#{permission_type})"
      true
    when :prompt
      show_media_permission_bar(decision.host, permission_type, request)
      true
    else
      false
    end
  end

  # Handles web notification permission requests
  #
  # @param webview [WebKit2Gtk::WebView] The webview making the request
  # @param request [WebKit2Gtk::NotificationPermissionRequest] The permission request
  # @return [Boolean] True to stop signal propagation
  def handle_notification_permission_request(webview, request)
    decision = @permission_request_manager.notification_request(webview.uri)

    case decision.action
    when :allow
      request.allow
      puts "Notification permission auto-allowed for #{decision.host}"
      true
    when :prompt
      show_notification_permission_bar(decision.host, request)
      true
    else
      false
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

      # The manager keeps a repeat of the same URL and title from becoming a
      # second visit; a fresh one is also when the favicon is worth fetching.
      if @history_manager.record_visit(uri, title) != :duplicate
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

  # ========================================
  # Autocomplete
  # ========================================

  # Handles autocomplete requests from the toolbar
  #
  # @param query [String] User's search query
  def handle_autocomplete(query)
    # Skip text that already names a location -- there is nothing to suggest
    if Domain::UrlClassifier.explicit_address?(query)
      @autocomplete_popover.hide
      return
    end

    # Skip for very short queries
    if query.length < 2
      @autocomplete_popover.hide
      return
    end

    # Get suggestions from autocomplete manager
    candidates = @autocomplete_manager.suggest(query)

    # Prepend raw query as first result so Enter searches/navigates the typed text
    raw_query_entry = {
      uri: query,
      title: "Search or navigate: #{query}",
      favicon: nil,
      frecency: Float::INFINITY  # Always highest priority
    }
    candidates = [raw_query_entry] + candidates

    @autocomplete_popover.update(candidates)
    @autocomplete_popover.show
  end

  # ========================================
  # Sidebar Operations
  # ========================================

  def show_tabs_sidebar
    @sidebar_component.show_tabs
  end

  def show_history_sidebar
    @sidebar_component.show_history
  end

  def show_queue_sidebar
    @sidebar_component.show_queue
  end

  def show_downloads_sidebar
    @sidebar_component.show_downloads
  end

  # ========================================
  # Queue Management
  # ========================================

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
    next_entry = @queue_navigation_manager.remove_current_and_advance(url)

    # Refresh queue if visible
    if @sidebar_component.mode == :queue
      @sidebar_component.refresh_current_view
    end

    # Navigate to next entry if it exists
    if next_entry
      current_tab.webview.load_uri(next_entry.url)
      puts "Removed from queue, navigating to: #{next_entry.display_title}"
    else
      puts "Removed from queue, no more entries"
    end
  end

  def move_selected_queue_entry_up
    move_selected_queue_entry(:up)
  end

  def move_selected_queue_entry_down
    move_selected_queue_entry(:down)
  end

  # Moves the entry highlighted in the queue sidebar, keeping it highlighted
  # where it lands
  #
  # @param direction [Symbol] :up or :down
  # @return [void]
  private def move_selected_queue_entry(direction)
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue

    entry = @sidebar_component.selected_queue_entry
    return unless entry

    moved = direction == :up ? @queue_manager.move_up(entry.id) : @queue_manager.move_down(entry.id)
    return unless moved

    @sidebar_component.refresh_current_view
    @sidebar_component.select_queue_entry(entry.id)

    puts "Moved #{direction}: #{entry.display_title}"
  end

  def navigate_to_next_queue_item
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    next_entry = @queue_navigation_manager.next_entry(current_url)
    return unless next_entry

    current_tab.webview.load_uri(next_entry.url)
    puts "Navigated to next queue item: #{next_entry.display_title}"
  end

  def navigate_to_previous_queue_item
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    previous_entry = @queue_navigation_manager.previous_entry(current_url)
    return unless previous_entry

    current_tab.webview.load_uri(previous_entry.url)
    puts "Navigated to previous queue item: #{previous_entry.display_title}"
  end

  def move_current_page_up_in_queue
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    moved = @queue_navigation_manager.move_current_up(current_url)
    return unless moved

    @sidebar_component.refresh_current_view
    puts "Moved current page up in queue: #{moved.display_title}"
  end

  def move_current_page_down_in_queue
    # Only works when queue sidebar is visible
    return unless @sidebar_component.mode == :queue && current_tab

    current_url = current_tab.webview.uri
    return unless current_url

    moved = @queue_navigation_manager.move_current_down(current_url)
    return unless moved

    @sidebar_component.refresh_current_view
    puts "Moved current page down in queue: #{moved.display_title}"
  end

  # ========================================
  # Favicon Handling
  # ========================================

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

  # ========================================
  # WebView Event Handlers
  # ========================================

  def on_load_changed(load_event)
    return unless current_tab

    if load_event == :finished
      uri = current_tab.webview.uri
      title = current_tab.webview.title

      if uri && !uri.empty?
        # The manager keeps a repeat of the same URL and title from becoming a
        # second visit; a fresh one is also when the favicon is worth fetching.
        if @history_manager.record_visit(uri, title) != :duplicate
          # Try to fetch favicon for this page
          @favicon_manager.fetch_and_save_favicon(uri) if @favicon_manager
        end
      end
    end
  end

  # Shows the crash page in a tab whose web process has died
  #
  # WebKit runs page content in its own process, so this costs one tab rather
  # than the window -- but only if something takes the blank tab over. The
  # reason is logged as well as shown, because "which tab, and was it a crash
  # or the memory limit" is what a later diagnosis needs.
  #
  # `load_alternate_html` rather than `load_html`: the tab keeps the URL it was
  # showing and its session history, so Ctrl+R reloads the real page instead of
  # the crash page.
  #
  # @param tab [Tab] Tab whose web process ended
  # @param reason [WebKit2Gtk::WebProcessTerminationReason] Why WebKit ended it
  def on_web_process_terminated(tab, reason)
    nickname = termination_reason_nickname(reason)
    url = tab.webview.uri
    html = Domain::CrashPage.html(url: url, reason: nickname)

    warn Domain::CrashPage.log_line(url: url, reason: nickname)

    if url && !url.empty?
      tab.webview.load_alternate_html(html, url, nil)
    else
      # A tab that never loaded anything has no URI to be an alternate for
      tab.webview.load_html(html, nil)
    end
  end

  # WebKit's termination reason as a plain string
  #
  # Domain::CrashPage takes the nickname ("exceeded-memory-limit") rather than
  # the enum, so the WebKit type stops here at the Framework boundary.
  #
  # @param reason [WebKit2Gtk::WebProcessTerminationReason, Symbol, String] What WebKit reported
  # @return [String] Reason nickname
  private def termination_reason_nickname(reason)
    reason.respond_to?(:nick) ? reason.nick.to_s : reason.to_s
  end

  # ========================================
  # UI Mode Toggles
  # ========================================

  def toggle_sidebar
    @sidebar_component.toggle
  end

  def toggle_zen_mode
    @zen_mode = !@zen_mode
    apply_chrome_visibility
  end

  # Reconciles chrome (toolbar + sidebar) visibility against every reason it
  # might be hidden. Called from both toggles (zen mode, video fullscreen) and
  # on tab switch, so overlapping reasons compose correctly -- see
  # Domain::ChromeVisibility.
  def apply_chrome_visibility
    if Domain::ChromeVisibility.hidden?(zen_mode: @zen_mode, video_fullscreen: video_fullscreen?)
      hide_chrome
    else
      show_chrome
    end
  end

  def video_fullscreen?
    current_tab&.fullscreen || false
  end

  def hide_chrome
    @toolbar.hide
    if @sidebar_component.visible
      # Directly manipulate widget to avoid changing @visible flag
      # (hiding chrome is a temporary override, not a preference change)
      @sidebar_visible_before_chrome_hidden = true
      @sidebar_component.widget.hide
      @paned.set_position(0)
    end
  end

  def show_chrome
    @toolbar.show_all
    if @sidebar_visible_before_chrome_hidden
      @sidebar_component.widget.show_all
      @paned.set_position(@sidebar_component.width)
      @sidebar_visible_before_chrome_hidden = false
    end
  end

  def toggle_dark_mode
    @settings_manager.toggle_dark_mode
    @dark_mode = @settings_manager.dark_mode

    # Toggle GTK theme variant (affects browser UI)
    gtk_settings = Gtk::Settings.default
    gtk_settings.set_property("gtk-application-prefer-dark-theme", @dark_mode)

    # Keep the toolbar's switch in sync whether this toggle came from the
    # switch itself or the Ctrl+D shortcut
    @toolbar_component.apply_dark_mode(@dark_mode)

    # Save settings
    @settings_manager.save

    puts @dark_mode ? "Moon Dark mode enabled" : "Sun Light mode enabled"
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

  def toggle_markdown_source
    return unless current_tab
    @markdown_handler.toggle_view(current_tab.webview)
  end

  # Add PDF bookmarks to a previously printed PDF
  # Prompts user to select the PDF file and adds bookmarks based on current markdown
  def add_pdf_bookmarks
    return unless current_tab
    return unless @markdown_handler.showing_markdown?(current_tab.webview)

    markdown_content = @markdown_handler.get_markdown_content(current_tab.webview)
    return unless markdown_content

    pdf_path = FileChooser.new(
      parent: self,
      title: "Select PDF to Add Bookmarks",
      filters: Domain::FileFilters.pdf
    ).choose.first
    return unless pdf_path

    # Off the main loop: opening and rewriting a PDF takes long enough to
    # freeze the window
    Thread.new do
      result = @pdf_bookmark_manager.add_bookmarks(pdf_path, markdown_content)
      GLib::Idle.add do
        report_pdf_bookmark_result(result, pdf_path)
        false
      end
    end
  end

  # @param result [Symbol] What the manager reported
  # @param pdf_path [String] PDF the user chose
  # @return [void]
  private def report_pdf_bookmark_result(result, pdf_path)
    if result == :added
      puts "✓ PDF bookmarks added to #{pdf_path}"
    else
      warn "✗ Failed to add PDF bookmarks to #{pdf_path} (#{result})"
    end
  end

  def toggle_reader_mode
    if @reader_view_active
      @reader_view.hide
      @reader_view_active = false
      return
    end

    return unless current_tab

    # Use JavaScript to extract article content directly in WebKit
    # This avoids GC conflicts between Nokogiri/libxml2 and GLib/librsvg
    script = Domain::ArticleExtractorJS.extraction_script

    webview = current_tab.webview
    webview.run_javascript(script, nil) do |source_object, async_result|
      begin
        js_result = source_object.run_javascript_finish(async_result)
        if js_result
          js_value = js_result.js_value

          # The JSCValue class doesn't expose to_string directly in Ruby bindings
          # We need to invoke the method via GObject introspection
          require 'gobject-introspection'
          repo = GObjectIntrospection::Repository.default

          # JavaScriptCore 4.1 is already loaded by webkit2-gtk
          begin
            repo.require('JavaScriptCore', '4.1')
          rescue GObjectIntrospection::RepositoryError
            # Already loaded, that's fine
          end

          value_info = repo.find('JavaScriptCore', 'Value')

          # Find to_string method and invoke it with receiver and empty args
          to_string_method = nil
          value_info.methods.each { |m| to_string_method = m if m.name == 'to_string' }

          json_str = to_string_method.invoke(js_value, [])
          article = JSON.parse(json_str)

          if article['content'] && !article['content'].empty?
            @reader_view.show(article['title'], article['content'])
            @reader_view_active = true
          else
            puts "Could not extract article content"
          end
        end
      rescue => e
        puts "Error extracting article: #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end
    end
  end

  # ========================================
  # Zoom Controls
  # ========================================

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

  # ========================================
  # Print Operations
  # ========================================

  def print_page
    return unless current_tab

    # Create print operation for the current webview
    print_op = WebKit2Gtk::PrintOperation.new(current_tab.webview)

    # Create page setup with zero margins for edge-to-edge printing
    page_setup = Gtk::PageSetup.new
    page_setup.set_top_margin(0, Gtk::Unit::MM)
    page_setup.set_bottom_margin(0, Gtk::Unit::MM)
    page_setup.set_left_margin(0, Gtk::Unit::MM)
    page_setup.set_right_margin(0, Gtk::Unit::MM)

    # Apply page setup to print operation
    print_op.set_page_setup(page_setup)

    # A markdown document printed to a PDF gets its headings as bookmarks. The
    # manager decides whether this job qualifies; the window only supplies what
    # it printed and where the job says it went.
    print_op.signal_connect('finished') do
      settings = print_op.print_settings
      @pdf_bookmark_manager.add_bookmarks_for_print(
        settings&.get('output-uri'),
        printed_markdown
      )
    end

    # Run the print dialog - user can select "Print to File" for PDF output
    response = print_op.run_dialog(self)

    case response
    when :print
      puts "Print started"
    when :cancel
      puts "Print cancelled"
    end
  end

  # The markdown behind the page being printed, if it is a rendered markdown
  # document rather than an ordinary page
  #
  # @return [String, nil] Markdown source
  private def printed_markdown
    return nil unless current_tab
    return nil unless @markdown_handler.showing_markdown?(current_tab.webview)

    @markdown_handler.get_markdown_content(current_tab.webview)
  end

  # ========================================
  # Window Operations
  # ========================================

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
      puts "Video popout opened for: #{url}"
    else
      puts "Video popout currently only works with YouTube videos"
    end
  end

  def open_site_permissions
    permissions_window = SitePermissionsWindow.new(
      sections: site_permission_sections,
      parent_window: self
    )
    permissions_window.set_application(self.application) if self.application
    permissions_window.show_all
  end

  # Describes the Site Permissions window: what each section lists and what
  # removing a row from it means. The window renders these and emits the
  # intents; only this method knows the manager.
  #
  # @return [Array<Hash>] Section descriptors in display order
  def site_permission_sections
    [
      {
        title: "Popup Permissions",
        description: "Sites allowed to show popups:",
        empty_text: "No sites have popup permissions",
        get_permissions: -> { @site_permission_manager.popup_permissions },
        on_remove: ->(permission) {
          @site_permission_manager.revoke_popup_permission(permission.host)
        }
      },
      {
        title: "Media Permissions",
        description: "Sites allowed to access camera/microphone:",
        empty_text: "No sites have media permissions",
        get_permissions: -> { @site_permission_manager.media_permissions },
        row_label: ->(permission) {
          "#{permission.host} - #{Domain::MediaPermissionType.describe(permission.permission_type)}"
        },
        on_remove: ->(permission) {
          @site_permission_manager.revoke_media_permission(permission.host, permission.permission_type)
        }
      },
      {
        title: "Notification Permissions",
        description: "Sites allowed to send notifications:",
        empty_text: "No sites have notification permissions",
        get_permissions: -> { @site_permission_manager.notification_permissions },
        on_remove: ->(permission) {
          @site_permission_manager.revoke_notification_permission(permission.host)
        }
      },
      {
        title: "Certificate Exceptions",
        description: "Sites with trusted self-signed/invalid certificates:",
        empty_text: "No certificate exceptions",
        get_permissions: -> { @site_permission_manager.certificate_exceptions },
        on_remove: ->(permission) {
          @site_permission_manager.revoke_certificate_exception(permission.host)
        }
      }
    ]
  end

  def open_file
    filepath = FileChooser.new(
      parent: self,
      title: "Open File",
      filters: Domain::FileFilters.open_file
    ).choose.first
    return unless filepath

    file_uri = "file://#{filepath}"

    # A blank tab is the one the user meant; anything else keeps its page
    if current_tab && current_tab.uri == "about:blank"
      current_tab.webview.load_uri(file_uri)
    else
      create_new_tab(file_uri)
    end

    puts "Opening file: #{filepath}"
  end

  # ========================================
  # Browser Lifecycle
  # ========================================

  def reload_browser
    puts "Reloading browser with latest code..."

    # Saves the open tabs, then starts a replacement process from the same
    # script; the new process restores the session this one leaves behind.
    @browser_restarter.restart(@tabs.map(&:uri), @current_tab_index, File.expand_path($PROGRAM_NAME))

    # Close this window (will quit the application)
    close
  end

  # Helper method to save current session (private - only called internally)
  private def save_current_session
    # A tab with no URI is skipped rather than saved as an invented URL;
    # Domain::SessionSnapshot decides what is worth restoring.
    @session_manager.save(@tabs.map(&:uri), @current_tab_index)
  end

  # ========================================
  # Download Management
  # ========================================

  # Shortest interval between two progress redraws of the same download
  DOWNLOAD_UI_UPDATE_INTERVAL = 2.0

  # Called when DownloadHandler has recorded a newly started download
  #
  # @param download [Download] The started download
  def on_download_started(download)
    download_ui_updates[download.id] = Time.at(0)
    refresh_downloads_ui
  end

  # Called for each progress update, throttled before it reaches the widgets
  #
  # @param download [Download] The download with its latest byte counts
  def on_download_progress(download)
    now = Time.now
    last_update = download_ui_updates[download.id] || Time.at(0)
    return if now - last_update < DOWNLOAD_UI_UPDATE_INTERVAL

    download_ui_updates[download.id] = now

    if @sidebar_component.mode == :downloads
      speed = calculate_download_speed(download.id, download.bytes_received)
      @download_list_view.update_progress(
        download.id,
        download.bytes_received,
        download.total_bytes || 0,
        speed
      )
    end

    update_download_badge
  end

  # Called when a download has finished successfully
  #
  # @param download [Download] The completed download
  def on_download_finished(download)
    forget_download_progress(download.id)
    refresh_downloads_ui
    show_download_complete_notification(download.basename, download.destination)
  end

  # Called when a download has failed
  #
  # @param download [Download] The failed download
  def on_download_failed(download)
    forget_download_progress(download.id)
    refresh_downloads_ui
    warn "Download failed: #{download.error_message}"
  end

  # Redraws the downloads sidebar (when visible) and the toolbar badge
  def refresh_downloads_ui
    @sidebar_component.refresh_current_view if @sidebar_component.mode == :downloads
    update_download_badge
  end

  # Last redraw time per download, for progress throttling
  def download_ui_updates
    @download_ui_updates ||= {}
  end

  def forget_download_progress(download_id)
    download_ui_updates.delete(download_id)
    @download_speed_tracker&.delete(download_id)
  end

  # Calculates download speed in bytes/sec
  #
  # @param download_id [Integer] Download ID
  # @param current_bytes [Integer] Current bytes downloaded
  # @return [Float] Speed in bytes/sec
  def calculate_download_speed(download_id, current_bytes)
    @download_speed_tracker ||= {}

    now = Time.now
    if @download_speed_tracker[download_id]
      prev_time, prev_bytes = @download_speed_tracker[download_id]
      time_diff = now - prev_time
      bytes_diff = current_bytes - prev_bytes

      speed = time_diff > 0 ? bytes_diff / time_diff : 0.0
    else
      speed = 0.0
    end

    @download_speed_tracker[download_id] = [now, current_bytes]
    speed
  end

  # Updates the toolbar download button badge
  def update_download_badge
    @toolbar_component.update_download_badge(
      @download_coordinator.badge_state,
      @download_coordinator.active_download_count
    )
  end

  # ========================================
  # Tag Management
  # ========================================

  private

  # Shows context menu for queue entry (right-click menu)
  # @param entry [Domain::QueueEntry] Queue entry the user right-clicked
  # @param event [Gdk::EventButton] Button press event for popup positioning
  def show_queue_entry_context_menu(entry, event)
    # Copy entry data to avoid reference invalidation after menu destruction
    entry_id = entry.id
    entry_url = entry.url

    menu = Gtk::Menu.new

    # Edit Tags item
    edit_tags_item = Gtk::MenuItem.new(label: "Edit Tags")
    edit_tags_item.signal_connect("activate") do
      # Re-fetch entry from database to ensure fresh data
      fresh_entry = @queue_manager.find_by_id(entry_id)
      show_tag_edit_dialog(fresh_entry) if fresh_entry
    end
    menu.append(edit_tags_item)

    # Refresh Metadata item
    refresh_metadata_item = Gtk::MenuItem.new(label: "Refresh Metadata")
    refresh_metadata_item.signal_connect("activate") do
      refresh_queue_entry_metadata(entry_id, entry_url)
    end
    menu.append(refresh_metadata_item)

    menu.show_all
    menu.popup_at_pointer(event)
  end

  # Shows tag edit dialog for queue entry
  # @param entry [Domain::QueueEntry] Queue entry to edit tags for
  def show_tag_edit_dialog(entry)
    dialog = TagEditDialog.new(
      self,  # parent window
      entry,
      get_all_tags: -> { @queue_manager.all_tags },
      get_assigned_tag_ids: ->(entry_id) { @queue_manager.tags_for_entry(entry_id).map(&:id) },
      on_assign_tag: ->(entry_id, tag_id) { @queue_manager.assign_tag(entry_id, tag_id) },
      on_unassign_tag: ->(entry_id, tag_id) { @queue_manager.unassign_tag(entry_id, tag_id) },
      on_create_tag: ->(tag_name) { @queue_manager.create_or_find_tag(tag_name) },
      on_tags_changed: -> {
        # Refresh queue sidebar if visible
        # Check mode atomically - no race condition because GTK main loop is single-threaded
        if @sidebar_component.mode == :queue
          @sidebar_component.refresh_current_view
        end
      }
    )
    dialog.show
  end

  # Refreshes metadata for a queue entry
  # Re-fetches page HTML and extracts title, favicon, YouTube metadata
  # Re-applies auto-tagging if URL is YouTube (does NOT remove existing tags)
  #
  # Gap 11 RESOLUTION: Refresh metadata behavior with non-YouTube URLs
  # The refresh handler calls fetch_metadata which ALWAYS checks youtube_video?(url).
  # This means:
  # 1. Non-YouTube URLs: Only title and favicon are refreshed (original behavior)
  # 2. URLs that redirect to YouTube: Will be tagged on refresh (allows correction)
  # 3. URLs initially mis-detected: Will be re-checked and tagged appropriately
  # This is INTENDED behavior - refresh allows re-tagging if URL status changes.
  #
  # @param entry [Hash] Queue entry with 'id', 'url'
  def refresh_queue_entry_metadata(entry_id, url)
    return unless entry_id && url

    # Enqueue work for background metadata worker
    @queue_metadata_worker.enqueue(entry_id, url)

    puts "Refreshing metadata for: #{url}"
  end

  # Shows a popup blocked notification bar
  # Creates the bar dynamically and destroys it when dismissed
  # Only one notification per host is shown
  # When allowed, automatically opens the popup
  #
  # @param host [String] Host that was blocked
  # @param destination_url [String] Full URL of the blocked popup
  # @param related_view [WebKit2Gtk::WebView] WebView to relate popup to
  def show_popup_blocked_notification(host, destination_url, related_view)
    # Don't create duplicate notifications for the same host
    return if @popup_notification_hosts.include?(host)
    @popup_notification_hosts.add(host)

    notification_bar = PopupNotificationBar.new(
      on_allow: ->(allowed_host) {
        decision = @popup_manager.allow_and_route(destination_url)
        @popup_notification_hosts.delete(allowed_host)

        # Open the popup that was blocked, where it belongs
        case decision.action
        when :oauth_window
          popup = PopupWindow.new(related_view, self)
          popup.webview.load_uri(decision.url)
          popup.show_all
        when :new_tab
          create_new_tab(decision.url, switch_to: true)
        end

        puts "Allowed popups for: #{allowed_host}"
      },
      on_dismiss: -> {
        @popup_notification_hosts.delete(host)
      }
    )
    notification_bar.set_host(host)

    # Add to top of content area
    @content_vbox.pack_start(notification_bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(notification_bar.widget, 0)
    notification_bar.widget.show_all
  end

  # Shows a media permission request notification bar
  # Creates the bar dynamically and destroys it when dismissed
  # Only one notification per host/permission is shown
  #
  # @param host [String] Host requesting permission
  # @param permission_type [Symbol] :audio, :video, or :audio_video
  # @param request [WebKit2Gtk::UserMediaPermissionRequest] The permission request
  def show_media_permission_bar(host, permission_type, request)
    key = "#{host}:#{permission_type}"

    # Don't create duplicate notifications for the same host/permission
    return if @media_permission_pending[key]
    @media_permission_pending[key] = request

    notification_bar = MediaPermissionBar.new(
      on_allow: ->(allowed_host, perm_type) {
        @site_permission_manager.allow_media("https://#{allowed_host}", perm_type)
        pending_request = @media_permission_pending.delete("#{allowed_host}:#{perm_type}")
        pending_request&.allow
        puts "Media permission allowed for #{allowed_host} (#{perm_type})"
      },
      on_deny: -> {
        pending_request = @media_permission_pending.delete(key)
        pending_request&.deny
        puts "Media permission denied for #{host} (#{permission_type})"
      }
    )
    notification_bar.set_request(host, permission_type)

    # Add to top of content area
    @content_vbox.pack_start(notification_bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(notification_bar.widget, 0)
    notification_bar.widget.show_all
  end

  # Shows a web notification permission request bar
  # Creates the bar dynamically and destroys it when dismissed
  # Only one notification per host is shown
  #
  # @param host [String] Host requesting notification permission
  # @param request [WebKit2Gtk::NotificationPermissionRequest] The permission request
  def show_notification_permission_bar(host, request)
    # Don't create duplicate notifications for the same host
    return if @notification_permission_pending.include?(host)
    @notification_permission_pending.add(host)

    notification_bar = NotificationPermissionBar.new(
      on_allow: ->(allowed_host) {
        @site_permission_manager.allow_notifications("https://#{allowed_host}")
        @notification_permission_pending.delete(allowed_host)
        request.allow
        puts "Notification permission allowed for #{allowed_host}"
      },
      on_deny: -> {
        @notification_permission_pending.delete(host)
        request.deny
        puts "Notification permission denied for #{host}"
      }
    )
    notification_bar.set_host(host)

    # Add to top of content area
    @content_vbox.pack_start(notification_bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(notification_bar.widget, 0)
    notification_bar.widget.show_all
  end

  # Shows the consent bar for a passkey request
  #
  # The handler already refuses a second request from the same page while
  # one is pending, so there is nothing to deduplicate here.
  #
  # @param prompt [Domain::PasskeyPrompt] What the page asked for
  # @param on_allow [Proc] Receives the index of the chosen passkey
  # @param on_cancel [Proc] Receives nothing
  def show_passkey_prompt_bar(prompt, on_allow:, on_cancel:)
    bar = PasskeyPromptBar.new(
      on_allow: ->(choice) {
        response = on_allow.call(choice)
        if response.resolved?
          puts "Passkey #{prompt.create? ? 'created' : 'used'} for #{prompt.rp_id}"
        else
          puts "Passkey request failed for #{prompt.rp_id}: #{response.error_message}"
        end
      },
      on_cancel: -> {
        on_cancel.call
        puts "Passkey request declined for #{prompt.rp_id}"
      }
    )
    bar.show_prompt(prompt)

    @content_vbox.pack_start(bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(bar.widget, 0)
    bar.widget.show_all
  end

  # Handles a web notification by sending it to dunst via notify-send
  #
  # @param webview [WebKit2Gtk::WebView] The webview that triggered the notification
  # @param notification [WebKit2Gtk::Notification] The notification to display
  # @return [Boolean] True to indicate the notification was handled
  def handle_web_notification(webview, notification)
    shown = @web_notification_dispatcher.dispatch(
      title: notification.title,
      body: notification.body,
      page_url: webview.uri
    )

    puts "Web notification from #{shown.host}: #{shown.title}"

    # Return true to indicate we handled the notification
    # This prevents WebKit from trying to show its own notification
    true
  end

  # Handles permission state queries from websites
  # Called when a site checks Notification.permission or similar
  #
  # @param webview [WebKit2Gtk::WebView] The webview making the query
  # @param query [WebKit2Gtk::PermissionStateQuery] The permission query
  # @return [Boolean] True to indicate we handled the query
  def handle_permission_state_query(_webview, query)
    permission_name = query.name
    origin = query.security_origin

    case @permission_request_manager.permission_state(permission_name, origin)
    when :granted
      query.finish(WebKit2Gtk::PermissionState::GRANTED)
      puts "Permission query for #{permission_name} from #{origin}: GRANTED"
      true
    when :prompt
      # PROMPT indicates the site has not been asked yet
      query.finish(WebKit2Gtk::PermissionState::PROMPT)
      puts "Permission query for #{permission_name} from #{origin}: PROMPT"
      true
    else
      false  # Not a permission we track; let WebKit handle it
    end
  end

  # Handles file chooser requests from <input type="file"> elements
  # Creates a custom file dialog with image preview support
  #
  # @param webview [WebKit2Gtk::WebView] The webview making the request
  # @param request [WebKit2Gtk::FileChooserRequest] The file chooser request
  # @return [Boolean] True to indicate we handled the request
  def handle_file_chooser_request(webview, request)
    # WebKit supplies a filter for the element's `accept` attribute; the rest
    # is what this browser adds on top of it
    filters = [request.mime_types_filter, *Domain::FileFilters.for_upload(request.mime_types)]

    chosen = FileChooser.new(
      parent: self,
      title: "Select File",
      filters: filters,
      select_multiple: request.select_multiple?,
      preview: true
    ).choose

    chosen.empty? ? request.cancel : request.select_files(chosen)

    # Return true to indicate we handled the request
    true
  end

  # Shows a download completion notification bar
  #
  # @param filename [String] Downloaded filename
  # @param filepath [String] Full path to downloaded file
  def show_download_complete_notification(filename, filepath)
    notification_bar = DownloadNotificationBar.new(
      on_open: ->(path) {
        @external_opener.open_path(path)
      },
      on_show_folder: ->(path) {
        @external_opener.open_containing_directory(path)
      },
      on_dismiss: -> {
        # Nothing to do
      }
    )
    notification_bar.set_download(filename, filepath)

    # Add to top of content area
    @content_vbox.pack_start(notification_bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(notification_bar.widget, 0)
    notification_bar.widget.show_all
  end

  # Shows a certificate exception notification bar for TLS errors
  # Creates the bar dynamically and destroys it when dismissed
  # Only one notification per host is shown
  #
  # @param host [String] Host with certificate error
  # @param failing_uri [String] Full URI that failed to load
  # @param certificate [Gio::TlsCertificate] The certificate that caused the error
  # @param tab [Tab] The tab that encountered the error
  def show_certificate_exception_bar(host, failing_uri, certificate, tab)
    # Don't create duplicate notifications for the same host
    return if @certificate_exception_pending.include?(host)
    @certificate_exception_pending.add(host)

    notification_bar = CertificateExceptionBar.new(
      on_allow: ->(allowed_host, uri) {
        @site_permission_manager.trust_certificate(allowed_host)
        @certificate_exception_pending.delete(allowed_host)

        # Allow the certificate in WebKit context and reload
        @web_context.allow_tls_certificate_for_host(certificate, allowed_host)
        tab.webview.load_uri(uri)

        puts "Certificate exception added for: #{allowed_host}"
      },
      on_dismiss: -> {
        @certificate_exception_pending.delete(host)
        # Go back if possible, otherwise load about:blank
        if tab.webview.can_go_back?
          tab.webview.go_back
        else
          tab.webview.load_uri("about:blank")
        end
      }
    )
    notification_bar.set_host(host, failing_uri)

    # Add to top of content area
    @content_vbox.pack_start(notification_bar.widget, expand: false, fill: false, padding: 0)
    @content_vbox.reorder_child(notification_bar.widget, 0)
    notification_bar.widget.show_all
  end

end
