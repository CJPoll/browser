require 'minitest/autorun'
require_relative '../../lib/managers/browser_restarter'

class ManagersBrowserRestarterTest < Minitest::Test
  A = 'https://a.example'.freeze
  B = 'https://b.example'.freeze
  SCRIPT = '/home/user/dev/browser/simple_browser.rb'.freeze

  class MockSessionManager
    attr_reader :saved

    def initialize
      @saved = []
    end

    def save(tab_uris, current_tab_index)
      @saved << [tab_uris, current_tab_index]
    end
  end

  class MockProcessLauncher
    attr_reader :launches

    def initialize
      @launches = []
    end

    def launch(*argv, **options)
      @launches << [argv, options]
      1234
    end
  end

  def setup
    @session_manager = MockSessionManager.new
    @process_launcher = MockProcessLauncher.new
    @restarter = Managers::BrowserRestarter.new(
      session_manager: @session_manager,
      process_launcher: @process_launcher
    )
  end

  def test_saves_the_open_tabs_before_relaunching
    @restarter.restart([A, B], 1, SCRIPT)

    assert_equal [[[A, B], 1]], @session_manager.saved
  end

  def test_launches_the_browser_again
    @restarter.restart([A], 0, SCRIPT)

    assert_equal [['ruby', SCRIPT]], @process_launcher.launches.map(&:first)
  end

  # Losing the tabs because the new process started first would defeat the
  # point of reloading, so the order is part of the contract.
  def test_saves_the_session_before_the_new_process_starts
    order = []
    session_manager = Object.new
    session_manager.define_singleton_method(:save) { |_uris, _index| order << :saved }
    launcher = Object.new
    launcher.define_singleton_method(:launch) { |*_argv, **_options| order << :launched }

    Managers::BrowserRestarter.new(session_manager: session_manager, process_launcher: launcher)
                              .restart([A], 0, SCRIPT)

    assert_equal %i[saved launched], order
  end

  def test_returns_the_new_process_id
    assert_equal 1234, @restarter.restart([A], 0, SCRIPT)
  end

  def test_passes_the_script_path_as_a_separate_argument
    @restarter.restart([A], 0, '/home/user/my browser/simple_browser.rb')

    assert_equal ['ruby', '/home/user/my browser/simple_browser.rb'],
                 @process_launcher.launches.first.first
  end
end
