# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/handlers/keyboard_handler'

# Ctrl+Shift+L triggers a login fill; the binding is added without disturbing
# the existing Ctrl+L (focus URL bar).
class KeyboardHandlerLoginFillTest < Minitest::Test
  def full_callbacks(overrides = {})
    {
      toolbar_actions: { focus_url_entry: -> { @focused = true }, show_toolbar: -> {}, in_zen_mode: -> { false } },
      sidebar_actions: { toggle: -> {}, show_tabs: -> {}, show_history: -> {}, show_queue: -> {}, visible: -> { false }, mode: -> { :tabs } },
      tab_actions: { create: -> {}, close_current: -> {}, next: -> {}, previous: -> {}, move_up: -> {}, move_down: -> {}, get_current: -> { nil } },
      navigation_actions: { go_back: -> {}, go_forward: -> {}, reload: -> {} },
      queue_actions: { add_current: -> {}, remove_and_next: -> {}, next_item: -> {}, previous_item: -> {}, move_current_up: -> {}, move_current_down: -> {}, find_queue_entry_by_url: ->(_) {}, show_tag_edit_dialog: ->(_) {} },
      zoom_actions: { zoom_in: -> {}, zoom_out: -> {}, reset: -> {} },
      mode_actions: { toggle_dark_mode: -> {}, toggle_zen_mode: -> {}, toggle_inspector: -> {} },
      window_actions: { reload_browser: -> {}, open_new_window: -> {}, open_video_popout: -> {}, open_site_permissions: -> {}, open_file: -> {}, print_page: -> {} },
      find_actions: { show_find_bar: -> {} },
      markdown_actions: { toggle_source: -> {}, add_pdf_bookmarks: -> {} },
      login_actions: { fill_current: -> { @filled = true } }
    }.merge(overrides)
  end

  def test_ctrl_shift_l_fills_the_current_login
    handler = KeyboardHandler.new(full_callbacks)
    event = create_key_event(Gdk::Keyval::KEY_L, control: true, shift: true)

    assert handler.handle_key_press(nil, event)
    assert @filled
  end

  def test_ctrl_l_still_focuses_the_url_bar
    handler = KeyboardHandler.new(full_callbacks)
    event = create_key_event(Gdk::Keyval::KEY_l, control: true)

    assert handler.handle_key_press(nil, event)
    assert @focused
    refute @filled
  end

  def test_missing_login_actions_group_is_rejected
    callbacks = full_callbacks
    callbacks.delete(:login_actions)

    error = assert_raises(ArgumentError) { KeyboardHandler.new(callbacks) }
    assert_match(/login_actions/, error.message)
  end
end
