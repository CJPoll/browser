require 'minitest/autorun'
require_relative '../../lib/managers/settings_manager'

class ManagersSettingsManagerTest < Minitest::Test
  class MockSettingsStore
    attr_reader :saved

    def initialize(stored: {})
      @stored = stored
      @saved = []
    end

    def save(settings)
      @saved << settings
      true
    end

    def load
      @stored
    end
  end

  def build_manager(stored: {})
    @store = MockSettingsStore.new(stored: stored)
    Managers::SettingsManager.new(store: @store)
  end

  # === Loading ===

  def test_defaults_to_light_mode_on_first_run
    refute build_manager.dark_mode
  end

  def test_reads_dark_mode_from_the_stored_settings
    assert build_manager(stored: { 'dark_mode' => true }).dark_mode
  end

  def test_treats_a_stored_false_as_light_mode
    refute build_manager(stored: { 'dark_mode' => false }).dark_mode
  end

  def test_treats_settings_written_by_another_version_as_light_mode
    refute build_manager(stored: { 'theme' => 'solarized' }).dark_mode
  end

  # === Toggling ===

  def test_toggling_turns_dark_mode_on
    manager = build_manager

    assert_equal true, manager.toggle_dark_mode
    assert manager.dark_mode
  end

  def test_toggling_twice_returns_to_where_it_started
    manager = build_manager
    manager.toggle_dark_mode
    manager.toggle_dark_mode

    refute manager.dark_mode
  end

  # The toggle changes the setting; writing it is a separate step, so a
  # temporary override (zen mode) can leave the stored preference alone.
  def test_toggling_does_not_write_to_the_store
    build_manager.toggle_dark_mode

    assert_empty @store.saved
  end

  # === Saving ===

  def test_saves_the_current_setting
    manager = build_manager
    manager.toggle_dark_mode
    manager.save

    assert_equal [{ 'dark_mode' => true }], @store.saved
  end

  def test_saves_light_mode_too
    build_manager(stored: { 'dark_mode' => true }).tap(&:toggle_dark_mode).save

    assert_equal [{ 'dark_mode' => false }], @store.saved
  end

  def test_reports_whether_the_settings_were_written
    assert_equal true, build_manager.save
  end
end
