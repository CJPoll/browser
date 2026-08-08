require_relative 'test_helper'
require_relative '../lib/ui/sidebar'
require_relative '../lib/ui/tab_list_view'
require_relative '../lib/ui/history_list_view'
require_relative '../lib/managers/history_manager'

# Note: test_helper already requires:
# - queue_manager
# - lib/ui/queue_list_view
# - gtk3

class FilterButtonVisibilityTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['queue_test', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @queue_manager = create_queue_manager(@temp_db_path)
    @history_manager = Managers::HistoryManager.new(
      repository: Repositories::HistoryRepository.new(
        db_path: File.join(File.dirname(@temp_db_path), 'history.db')
      )
    )

    # Create view components
    @tab_list_view = TabListView.new(create_favicon_creator)
    @history_list_view = HistoryListView.new(@history_manager, create_favicon_creator)
    @queue_list_view = QueueListView.new(@queue_manager, create_favicon_creator)

    # Create sidebar
    @sidebar = Sidebar.new(
      {
        tab_list_view: @tab_list_view,
        history_list_view: @history_list_view,
        queue_list_view: @queue_list_view
      },
      {
        get_tabs: -> { [[], 0] },
        get_current_tab: -> { nil },
        get_queue_count: -> { @queue_manager.count },
        get_paned: -> { Gtk::Paned.new(:horizontal) }
      }
    )
  end

  def teardown
    if @queue_manager
      @queue_manager.close
    end
    @history_manager&.close
    File.delete(@temp_db_path) if File.exist?(@temp_db_path)
    history_path = File.join(File.dirname(@temp_db_path), 'history.db')
    File.delete(history_path) if File.exist?(history_path)
  end

  def test_filter_button_hidden_in_tabs_mode
    @sidebar.show_tabs

    filter_button = @sidebar.instance_variable_get(:@filter_button)
    assert_equal false, filter_button.visible?, "Filter button should be hidden in tabs mode"
  end

  def test_filter_button_hidden_in_history_mode
    @sidebar.show_history

    filter_button = @sidebar.instance_variable_get(:@filter_button)
    assert_equal false, filter_button.visible?, "Filter button should be hidden in history mode"
  end

  def test_filter_button_visible_in_queue_mode
    @sidebar.show_queue

    filter_button = @sidebar.instance_variable_get(:@filter_button)
    assert_equal true, filter_button.visible?, "Filter button should be visible in queue mode"
  end

  def test_sort_button_visible_in_queue_mode
    @sidebar.show_queue

    sort_button = @sidebar.instance_variable_get(:@sort_button)
    assert_equal true, sort_button.visible?, "Sort button should be visible in queue mode"
  end
end
