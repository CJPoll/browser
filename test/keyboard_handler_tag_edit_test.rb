require_relative 'test_helper'
require_relative '../lib/handlers/keyboard_handler'

class KeyboardHandlerTagEditTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = QueueManager.new(@temp_db_path)

    # Add queue entry
    @queue_manager.add("https://example.com", "Test Page")
    @entry = @queue_manager.find_by_url("https://example.com")

    # Mock current tab and webview
    @current_webview = Object.new
    @current_tab = Object.new
    @current_tab.define_singleton_method(:webview) { @current_webview }

    # Track dialog invocations
    @dialog_opened_for = nil

    # Set initial URI
    @current_webview_uri = "https://example.com"

    # Create keyboard handler (will be recreated in tests as needed)
    @keyboard_handler = KeyboardHandler.new(
      create_minimal_keyboard_handler_callbacks
    )
  end

  def teardown
    if @queue_manager
      db = @queue_manager.instance_variable_get(:@db)
      begin
        db.close unless db.closed?
      rescue SQLite3::Exception
        # Ignore
      end
    end
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
  end

  def test_ctrl_alt_t_opens_dialog_for_queued_page
    # Recreate handler with fixed current_tab that has properly mocked webview
    @current_webview_uri = "https://example.com"

    @keyboard_handler = KeyboardHandler.new(
      create_minimal_keyboard_handler_callbacks
    )

    # Create key event (Ctrl+Alt+T)
    event = create_key_event(Gdk::Keyval::KEY_t,
                            control: true,
                            alt: true,
                            shift: false)

    # Handle event
    result = @keyboard_handler.handle_key_press(nil, event)

    # Verify dialog opened
    assert result, "Handler should return true"
    assert_not_nil @dialog_opened_for, "Dialog should be opened"
    assert_equal "https://example.com", @dialog_opened_for['url'], "Dialog should open for correct entry"
  end

  def test_ctrl_alt_t_no_op_for_non_queued_page
    # Recreate handler with non-queued URL
    @current_webview_uri = "https://other-site.com"

    @keyboard_handler = KeyboardHandler.new(
      create_minimal_keyboard_handler_callbacks
    )

    # Create key event (Ctrl+Alt+T)
    event = create_key_event(Gdk::Keyval::KEY_t,
                            control: true,
                            alt: true,
                            shift: false)

    # Handle event
    result = @keyboard_handler.handle_key_press(nil, event)

    # Verify dialog NOT opened
    assert_nil @dialog_opened_for, "Dialog should not be opened"
    refute result, "Handler should return false (not handled)"
  end

  def test_ctrl_alt_t_no_op_when_no_current_tab
    # Override get_current to return nil
    callbacks = create_minimal_keyboard_handler_callbacks

    callbacks[:tab_actions][:get_current] = -> { nil }

    @keyboard_handler = KeyboardHandler.new(callbacks)

    # Create key event (Ctrl+Alt+T)
    event = create_key_event(Gdk::Keyval::KEY_t,
                            control: true,
                            alt: true,
                            shift: false)

    # Handle event
    result = @keyboard_handler.handle_key_press(nil, event)

    # Verify dialog NOT opened
    assert_nil @dialog_opened_for, "Dialog should not be opened"
    refute result, "Handler should return false (not handled)"
  end

  private

  # Creates minimal keyboard handler callbacks for Ctrl+Alt+T testing
  # Returns hash of callbacks that can be passed to KeyboardHandler.new
  def create_minimal_keyboard_handler_callbacks
    # Capture self so we can access instance variables in closures
    test_self = self

    # Create mock webview that returns the stored URI
    webview = Object.new
    webview.define_singleton_method(:uri) do
      test_self.instance_variable_get(:@current_webview_uri)
    end

    # Create mock current_tab that uses the webview
    tab = Object.new
    tab.define_singleton_method(:webview) { webview }

    # Create stubs for all required callback groups
    # Most callbacks are no-ops for this test
    {
      toolbar_actions: {
        focus_url_entry: -> {},
        show_toolbar: -> {},
        in_zen_mode: -> { false }
      },
      sidebar_actions: {
        toggle: -> {},
        show_tabs: -> {},
        show_history: -> {},
        show_queue: -> {},
        visible: -> { false },
        mode: -> { :queue }
      },
      tab_actions: {
        create: -> {},
        close_current: -> {},
        next: -> {},
        previous: -> {},
        move_up: -> {},
        move_down: -> {},
        get_current: -> { tab }
      },
      navigation_actions: {
        go_back: -> {},
        go_forward: -> {},
        reload: -> {}
      },
      queue_actions: {
        add_current: -> {},
        remove_and_next: -> {},
        next_item: -> {},
        previous_item: -> {},
        move_current_up: -> {},
        move_current_down: -> {},
        # THE TWO CALLBACKS WE ACTUALLY TEST:
        find_queue_entry_by_url: ->(url) { @queue_manager.find_by_url(url) },
        show_tag_edit_dialog: ->(entry) { @dialog_opened_for = entry }
      },
      zoom_actions: {
        zoom_in: -> {},
        zoom_out: -> {},
        reset: -> {}
      },
      mode_actions: {
        toggle_dark_mode: -> {},
        toggle_zen_mode: -> {},
        toggle_inspector: -> {}
      },
      window_actions: {
        reload_browser: -> {},
        open_new_window: -> {},
        open_video_popout: -> {}
      }
    }
  end
end
