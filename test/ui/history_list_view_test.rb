require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/domain/page'
require_relative '../../lib/domain/visit'
require_relative '../../lib/ui/history_list_view'

# The view is a UI Component: these tests hand it plain arrays instead of a
# history manager and check that it renders what it is given and reports what
# the user asked for.
#
# Note: GTK signal emission does not reach Ruby handlers under minitest in this
# environment, so the remove button cannot be clicked. Its handler is a
# one-line call to `delete_visit`, and that is what these tests drive.
class HistoryListViewTest < Minitest::Test
  VISITED_AT = Time.at(1_700_000_000).freeze

  def setup
    @visits = []
    @search_results = []
    @searches = []
    @deleted = []

    @view = HistoryListView.new(
      create_favicon_image: ->(_favicon) { Gtk::Image.new },
      get_recent_visits: ->(limit) { @visits.take(limit) },
      get_search_results: ->(query, limit) { @searches << [query, limit]; @search_results.take(limit) },
      on_delete_visit: ->(visit_id) { @deleted << visit_id }
    )
  end

  def build_visit(id:, uri: "https://example.com/#{id}", title: "Page #{id}")
    Domain::Visit.new(
      id: id,
      visited_at: VISITED_AT,
      title: title,
      page: Domain::Page.new(id: id, uri: uri, title: title)
    )
  end

  def build_page(id:, uri: "https://example.com/#{id}", title: "Page #{id}")
    Domain::Page.new(id: id, uri: uri, title: title, last_visited_at: VISITED_AT)
  end

  def rows
    @view.list_widget.children
  end

  def labels_in(widget)
    return [widget] if widget.is_a?(Gtk::Label)
    return [] unless widget.respond_to?(:children)

    widget.children.flat_map { |child| labels_in(child) }
  end

  def row_texts
    rows.flat_map { |row| labels_in(row).map(&:text) }
  end

  # --- Recent visits ---

  def test_renders_one_row_per_recent_visit
    @visits = [build_visit(id: 1), build_visit(id: 2)]

    @view.refresh

    assert_equal 2, rows.length
    assert_includes row_texts, "https://example.com/1"
  end

  def test_refresh_replaces_previous_rows
    @visits = [build_visit(id: 1)]
    @view.refresh

    @visits = [build_visit(id: 2), build_visit(id: 3)]
    @view.refresh

    assert_equal 2, rows.length
  end

  def test_refresh_passes_the_limit_to_the_data_source
    @visits = [build_visit(id: 1), build_visit(id: 2), build_visit(id: 3)]

    @view.refresh(2)

    assert_equal 2, rows.length
  end

  def test_renders_nothing_when_built_without_callbacks
    view = HistoryListView.new

    view.refresh

    assert_empty view.list_widget.children
  end

  # --- Search ---

  def test_searching_renders_the_search_results
    @search_results = [build_page(id: 5, title: "Found")]

    @view.search("found")

    assert_equal [["found", 50]], @searches
    assert_includes row_texts, "https://example.com/5"
  end

  def test_a_search_with_no_results_says_so
    @view.search("nothing")

    assert_includes row_texts, 'No results found for "nothing"'
  end

  def test_a_blank_search_falls_back_to_recent_visits
    @visits = [build_visit(id: 1)]

    @view.search("   ")

    assert_empty @searches
    assert_equal 1, rows.length
  end

  # --- Intents ---

  def test_delete_visit_reports_the_intent_and_redraws
    @visits = [build_visit(id: 1), build_visit(id: 2)]
    @view.refresh
    @visits = [build_visit(id: 2)]

    @view.delete_visit(1)

    assert_equal [1], @deleted
    assert_equal 1, rows.length
  end

  # --- Bucket rules ---

  # ADR 001: a UI component may not hold a manager, repository or adapter.
  def test_holds_no_manager_or_repository
    collaborators = @view.instance_variables.map { |name| @view.instance_variable_get(name) }

    assert(collaborators.none? { |value| value.class.name.to_s =~ /Manager|Repository|Adapter/ })
    refute @view.respond_to?(:history_manager),
           "UI Components must not expose a manager (ADR 001)"
  end
end
