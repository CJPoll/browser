require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/domain/queue_entry'
require_relative '../../lib/ui/sidebar'
require_relative '../../lib/ui/tab_list_view'
require_relative '../../lib/ui/history_list_view'
require_relative '../../lib/ui/queue_list_view'
require_relative '../../lib/ui/download_list_view'

# The sidebar starts at the narrowest width its contents fit in: wide enough
# that nothing is pushed out of view, and no wider. These tests pin where that
# number comes from -- GTK's own minimum for the widget tree -- rather than any
# particular pixel count, which depends on the theme and the entries on screen.
class SidebarWidthTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def setup
    @entries = [
      Domain::QueueEntry.new(
        id: 1,
        url: 'https://example.com/an/article',
        title: 'A title long enough that it has to ellipsize',
        added_at: ADDED_AT,
        position: 1
      )
    ]
    @sidebar = build_sidebar
  end

  def test_reports_the_gtk_minimum_for_its_contents
    minimum, _natural = @sidebar.widget.preferred_width

    assert_operator @sidebar.minimum_content_width, :>, 0
    assert_equal minimum, @sidebar.minimum_content_width
  end

  def test_defaults_its_width_to_the_narrowest_its_contents_fit_in
    assert_equal @sidebar.minimum_content_width, @sidebar.width
  end

  def test_an_explicit_initial_width_wins_over_the_measured_one
    sidebar = build_sidebar(initial_width: 500)

    assert_equal 500, sidebar.width
  end

  def test_the_measured_width_follows_the_view_on_screen
    @sidebar.show_tabs
    tabs_width = @sidebar.minimum_content_width

    @sidebar.show_queue

    assert_operator @sidebar.minimum_content_width, :>, tabs_width,
                    'queue mode adds the filter and sort buttons to the header'
  end

  private

  def build_sidebar(initial_width: nil)
    Sidebar.new(view_components, callbacks, initial_width: initial_width)
  end

  def view_components
    {
      tab_list_view: TabListView.new(->(_favicon_data) { Gtk::Image.new }),
      history_list_view: HistoryListView.new(get_history: -> { [] }),
      queue_list_view: queue_list_view,
      download_list_view: DownloadListView.new(get_downloads: -> { [] })
    }
  end

  def queue_list_view
    QueueListView.new(
      create_favicon_image: ->(_favicon_data) { Gtk::Image.new },
      get_entries: ->(_tag_ids) { @entries },
      get_total_count: -> { @entries.length },
      get_tags_for_entry: ->(_entry_id) { [] },
      get_tag_usages: -> { [] },
      find_tag_by_name: ->(_name) { nil },
      find_tag_by_id: ->(_id) { nil },
      on_remove_entry: ->(_entry_id) {},
      on_move_entry: ->(_entry_id, _position) { true }
    )
  end

  def callbacks
    paned = Gtk::Paned.new(:horizontal)

    {
      get_tabs: -> { [[], 0] },
      get_current_tab: -> { nil },
      get_queue_count: -> { @entries.length },
      get_download_count: -> { 0 },
      get_paned: -> { paned }
    }
  end
end
