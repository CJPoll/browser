require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/ui/toolbar'

# The toolbar is a UI Component: these tests only check that it renders the
# dark-mode switch and exposes the tested public seams the Framework relies
# on to keep it in sync.
#
# Note: GTK signal emission does not reach Ruby handlers under minitest in
# this environment, so flipping the switch and observing "notify::active"
# fire cannot be simulated here. That is exactly why the switch's
# programmatic re-render path (`apply_dark_mode`) is a public method rather
# than something only a real user event could reach.
class ToolbarTest < Minitest::Test
  def build_callbacks(overrides = {})
    {
      on_sidebar_toggle: -> {},
      on_back: -> {},
      on_forward: -> {},
      on_load_url: -> {},
      on_reader_toggle: -> {},
      on_downloads_toggle: -> {},
      get_current_tab: -> { nil },
      in_zen_mode: -> { false },
      get_download_state: -> { :none }
    }.merge(overrides)
  end

  # Collects every Gtk::Switch in a widget tree.
  def switches_in(widget)
    return [widget] if widget.is_a?(Gtk::Switch)
    return [] unless widget.respond_to?(:children)

    widget.children.flat_map { |child| switches_in(child) }
  end

  def test_the_widget_tree_contains_a_dark_mode_switch
    toolbar = Toolbar.new(build_callbacks)

    assert_equal 1, switches_in(toolbar.widget).length
  end

  def test_initial_state_honors_get_dark_mode_true
    toolbar = Toolbar.new(build_callbacks(get_dark_mode: -> { true }))

    switch = switches_in(toolbar.widget).first
    assert switch.active?
  end

  def test_initial_state_honors_get_dark_mode_false
    toolbar = Toolbar.new(build_callbacks(get_dark_mode: -> { false }))

    switch = switches_in(toolbar.widget).first
    refute switch.active?
  end

  def test_initial_state_defaults_to_false_with_no_get_dark_mode_callback
    toolbar = Toolbar.new(build_callbacks)

    switch = switches_in(toolbar.widget).first
    refute switch.active?
  end

  def test_apply_dark_mode_sets_the_switch_active
    toolbar = Toolbar.new(build_callbacks)

    toolbar.apply_dark_mode(true)
    assert switches_in(toolbar.widget).first.active?

    toolbar.apply_dark_mode(false)
    refute switches_in(toolbar.widget).first.active?
  end

  def test_apply_dark_mode_is_idempotent_across_repeated_calls
    toolbar = Toolbar.new(build_callbacks)

    toolbar.apply_dark_mode(true)
    toolbar.apply_dark_mode(true)
    assert switches_in(toolbar.widget).first.active?

    toolbar.apply_dark_mode(false)
    toolbar.apply_dark_mode(false)
    refute switches_in(toolbar.widget).first.active?
  end

  def test_the_toolbar_exposes_no_manager
    toolbar = Toolbar.new(build_callbacks)

    refute toolbar.respond_to?(:settings_manager)
  end

  # Collects every Gtk::Button in a widget tree.
  def buttons_in(widget)
    found = widget.is_a?(Gtk::Button) ? [widget] : []
    found + (widget.respond_to?(:children) ? widget.children.flat_map { |child| buttons_in(child) } : [])
  end

  def test_has_a_login_fill_button
    toolbar = Toolbar.new(build_callbacks)

    tooltips = buttons_in(toolbar.widget).map(&:tooltip_text)
    assert_includes tooltips, 'Fill login from 1Password (Ctrl+Shift+L)'
  end

  def test_builds_without_an_on_fill_login_callback
    # The callback is optional (invoked with &.call), so a toolbar built
    # without it still constructs.
    Toolbar.new(build_callbacks)
  end
end
