require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../lib/adapters/session_store'
require_relative '../../lib/managers/session_manager'

# The session hand-off end to end: a closing window saves its tabs, and the
# next window reads them back. Real store, real file, no mocks.
class SessionFlowTest < Minitest::Test
  A = 'https://a.example'.freeze
  B = 'https://b.example'.freeze

  def setup
    @data_dir = Dir.mktmpdir('session-flow-test')
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && Dir.exist?(@data_dir)
  end

  def build_manager
    Managers::SessionManager.new(store: Adapters::SessionStore.new(data_dir: @data_dir))
  end

  def session_file_contents
    JSON.parse(File.read(File.join(@data_dir, 'session.json')))
  end

  def test_tabs_survive_a_restart
    build_manager.save([A, B], 1)

    snapshot = build_manager.restore
    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  def test_a_window_with_no_tabs_leaves_nothing_to_restore
    build_manager.save([], 0)

    assert_nil build_manager.restore
  end

  def test_the_next_window_after_a_restore_starts_fresh
    build_manager.save([A], 0)
    build_manager.restore

    assert_nil build_manager.restore
  end

  # Wart fix: a tab that never finished loading has no URI, and used to be
  # written to the session file as "https://www.google.com".
  def test_a_tab_with_no_uri_is_not_saved_as_an_invented_url
    build_manager.save([A, nil], 0)

    assert_equal [A], session_file_contents['tabs']
    refute_includes session_file_contents['tabs'].join, 'google.com'
  end

  def test_the_selected_tab_still_points_at_the_right_page_after_a_drop
    build_manager.save([A, nil, B], 2)

    snapshot = build_manager.restore
    assert_equal B, snapshot.tab_urls[snapshot.current_tab_index]
  end
end
