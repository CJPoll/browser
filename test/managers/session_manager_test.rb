require 'minitest/autorun'
require_relative '../../lib/managers/session_manager'

class ManagersSessionManagerTest < Minitest::Test
  A = 'https://a.example'.freeze
  B = 'https://b.example'.freeze

  class MockSessionStore
    attr_reader :saved

    def initialize(stored: nil)
      @stored = stored
      @saved = []
    end

    def save(session)
      @saved << session
      true
    end

    def load
      stored = @stored
      @stored = nil # loading consumes the session
      stored
    end
  end

  def setup
    @store = MockSessionStore.new
    @manager = Managers::SessionManager.new(store: @store)
  end

  # === Saving ===

  def test_saves_the_tabs_and_the_selected_one
    @manager.save([A, B], 1)

    assert_equal [{ 'tabs' => [A, B], 'current_tab_index' => 1 }], @store.saved
  end

  # Wart fix: a tab that never got a URI used to be saved as a Google URL.
  def test_does_not_invent_a_url_for_a_tab_that_has_none
    @manager.save([A, nil, B], 0)

    assert_equal [A, B], @store.saved.first['tabs']
  end

  def test_moves_the_selection_with_the_tabs_that_survive
    @manager.save([A, nil, B], 2)

    assert_equal 1, @store.saved.first['current_tab_index']
  end

  def test_returns_the_snapshot_it_saved
    snapshot = @manager.save([A, B], 1)

    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  def test_saves_an_empty_session_for_a_window_with_nothing_to_restore
    @manager.save([nil], 0)

    assert_equal [{ 'tabs' => [], 'current_tab_index' => 0 }], @store.saved
  end

  # === Restoring ===

  def test_restores_the_saved_session
    manager = Managers::SessionManager.new(
      store: MockSessionStore.new(stored: { 'tabs' => [A, B], 'current_tab_index' => 1 })
    )

    snapshot = manager.restore
    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  def test_restores_nothing_when_no_session_was_saved
    assert_nil @manager.restore
  end

  def test_restores_nothing_from_a_session_with_no_tabs
    manager = Managers::SessionManager.new(
      store: MockSessionStore.new(stored: { 'tabs' => [], 'current_tab_index' => 0 })
    )

    assert_nil manager.restore
  end

  def test_a_restored_session_is_not_restored_again
    manager = Managers::SessionManager.new(
      store: MockSessionStore.new(stored: { 'tabs' => [A], 'current_tab_index' => 0 })
    )
    manager.restore

    assert_nil manager.restore
  end

  def test_a_session_survives_a_save_and_restore_round_trip
    store = MockSessionStore.new
    Managers::SessionManager.new(store: store).save([A, B], 1)
    store_with_session = MockSessionStore.new(stored: store.saved.first)

    snapshot = Managers::SessionManager.new(store: store_with_session).restore
    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end
end
