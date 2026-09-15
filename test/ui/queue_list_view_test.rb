require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/domain/queue_entry'
require_relative '../../lib/domain/tag'
require_relative '../../lib/domain/tag_usage'
require_relative '../../lib/ui/queue_list_view'

# The view is a UI Component: these tests hand it plain arrays instead of a
# queue manager and check that it renders what it is given and reports what the
# user asked for.
#
# Note: GTK signal emission does not reach Ruby handlers under minitest in this
# environment, so button clicks cannot be simulated. Each button's handler is a
# one-line call to a public method, and that method is what these tests drive.
class QueueListViewTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def setup
    @entries = []
    @tags_by_entry = {}
    @tags = []
    @tag_usages = []
    @removed = []
    @moves = []
    @move_result = true

    @view = QueueListView.new(**callbacks)
  end

  def callbacks
    {
      create_favicon_image: ->(_favicon_data) { Gtk::Image.new },
      get_entries: ->(tag_ids) { entries_for(tag_ids) },
      get_total_count: -> { @entries.length },
      get_tags_for_entry: ->(entry_id) { @tags_by_entry.fetch(entry_id, []) },
      get_tag_usages: -> { @tag_usages },
      find_tag_by_name: ->(name) { @tags.find { |tag| tag.same_name?(name) } },
      find_tag_by_id: ->(id) { @tags.find { |tag| tag.id == id } },
      on_remove_entry: ->(entry_id) { @removed << entry_id; @entries.reject! { |e| e.id == entry_id } },
      on_move_entry: ->(entry_id, position) { @moves << [entry_id, position]; @move_result }
    }
  end

  # Stands in for Managers::QueueManager#entries_for_filter: no filter means
  # everything, otherwise only entries carrying every selected tag.
  def entries_for(tag_ids)
    return @entries if tag_ids.nil? || tag_ids.empty?

    @entries.select do |entry|
      assigned = @tags_by_entry.fetch(entry.id, []).map(&:id)
      tag_ids.all? { |tag_id| assigned.include?(tag_id) }
    end
  end

  def build_entry(id:, title: nil, position: id, published_at: nil)
    Domain::QueueEntry.new(
      id: id,
      url: "https://example.com/#{id}",
      title: title,
      position: position,
      published_at: published_at,
      added_at: ADDED_AT
    )
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

  # Gtk::Label#label returns the raw markup (unlike #text, which strips it).
  def row_markups
    rows.flat_map { |row| labels_in(row).map(&:label) }
  end

  # --- Rendering ---

  def test_renders_one_row_per_entry
    @entries = [build_entry(id: 1, title: "First"), build_entry(id: 2, title: "Second")]

    @view.refresh

    assert_equal 2, rows.length
  end

  def test_title_is_rendered_at_x_large_size
    @entries = [build_entry(id: 1, title: "First")]

    @view.refresh

    title_markup = row_markups.find { |markup| markup.include?("First") }
    refute_nil title_markup
    assert_includes title_markup, "size='x-large'"
  end

  def test_refresh_replaces_previous_rows
    @entries = [build_entry(id: 1, title: "First")]
    @view.refresh

    @entries = [build_entry(id: 2, title: "Second"), build_entry(id: 3, title: "Third")]
    @view.refresh

    assert_equal 2, rows.length
    assert_includes row_texts, "https://example.com/2"
  end

  def test_renders_nothing_when_built_without_callbacks
    view = QueueListView.new

    view.refresh

    assert_empty view.list_widget.children
  end

  def test_renders_the_tags_of_each_entry
    entry = build_entry(id: 1, title: "Tagged")
    @entries = [entry]
    @tags_by_entry[1] = [Domain::Tag.new(id: 7, name: "Gaming")]

    @view.refresh

    assert_includes row_texts, "Gaming"
  end

  def test_reports_filtered_and_total_counts_after_refresh
    reported = nil
    @entries = [build_entry(id: 1), build_entry(id: 2)]
    @tags_by_entry[1] = [Domain::Tag.new(id: 7, name: "Gaming")]
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]
    @view.on_queue_modified = ->(filtered, total) { reported = [filtered, total] }

    @view.add_filter_tag(7)

    assert_equal [1, 2], reported
  end

  def test_shows_the_empty_state_when_a_filter_matches_nothing
    @entries = [build_entry(id: 1)]
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]

    @view.add_filter_tag(7)

    assert_includes row_texts, "No entries match the selected filters."
  end

  # --- Sorting ---

  def test_sort_mode_reorders_the_rendered_rows
    @entries = [build_entry(id: 1, title: "Zebra"), build_entry(id: 2, title: "Alpha")]
    @view.refresh

    @view.set_sort_mode(:title)

    assert_equal "Alpha", labels_in(rows.first).map(&:text).first
  end

  def test_sort_mode_defaults_to_position
    assert_equal :position, @view.current_sort_mode
  end

  # --- Intents ---

  def test_remove_entry_reports_the_intent_and_redraws
    @entries = [build_entry(id: 1), build_entry(id: 2)]
    @view.refresh

    @view.remove_entry(1)

    assert_equal [1], @removed
    assert_equal 1, rows.length
  end

  def test_move_entry_reports_the_intent_and_redraws
    @entries = [build_entry(id: 1), build_entry(id: 2)]
    @view.refresh

    @view.move_entry(2, 1)

    assert_equal [[2, 1]], @moves
    assert_equal 2, rows.length
  end

  def test_move_entry_leaves_the_list_alone_when_the_move_is_refused
    @entries = [build_entry(id: 1)]
    @view.refresh
    rendered = rows
    @move_result = false

    @view.move_entry(1, 9)

    assert_equal [[1, 9]], @moves
    assert_equal rendered, rows
  end

  # --- Selection ---
  #
  # BrowserWindow moves "the entry the user has highlighted" up and down the
  # queue, and used to read the entry off the selected row itself. These two
  # methods are what it asks instead.

  def test_selected_entry_is_nothing_until_a_row_is_selected
    @entries = [build_entry(id: 1)]
    @view.refresh

    assert_nil @view.selected_entry
  end

  def test_selected_entry_is_the_entry_behind_the_selected_row
    @entries = [build_entry(id: 1, title: "First"), build_entry(id: 2, title: "Second")]
    @view.refresh

    assert @view.select_entry(2)
    assert_equal 2, @view.selected_entry.id
    assert_equal "Second", @view.selected_entry.title
  end

  def test_select_entry_reports_an_entry_that_is_not_on_screen
    @entries = [build_entry(id: 1)]
    @view.refresh

    refute @view.select_entry(99)
    assert_nil @view.selected_entry
  end

  def test_select_entry_follows_an_entry_that_moved
    @entries = [build_entry(id: 1), build_entry(id: 2)]
    @view.refresh
    @view.select_entry(2)

    # The manager reorders, the window redraws, and the moved entry stays
    # highlighted where it landed
    @entries = [build_entry(id: 2), build_entry(id: 1)]
    @view.refresh
    @view.select_entry(2)

    assert_equal 2, @view.selected_entry.id
    assert_equal @view.list_widget.children.first, @view.list_widget.selected_row
  end

  def test_a_refresh_clears_the_selection_until_it_is_restored
    @entries = [build_entry(id: 1), build_entry(id: 2)]
    @view.refresh
    @view.select_entry(1)

    @view.refresh

    assert_nil @view.selected_entry
  end

  # --- Filters ---

  def test_active_filter_tag_names_resolves_ids_through_the_data_source
    @tags = [Domain::Tag.new(id: 7, name: "Gaming"), Domain::Tag.new(id: 8, name: "Tutorial")]

    @view.add_filter_tag(8)
    @view.add_filter_tag(7)

    assert_equal ["Tutorial", "Gaming"], @view.active_filter_tag_names
  end

  def test_active_filter_tag_names_skips_ids_the_data_source_no_longer_knows
    @view.add_filter_tag(99)

    assert_empty @view.active_filter_tag_names
  end

  def test_filter_by_tag_name_looks_the_tag_up_and_filters
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]

    @view.filter_by_tag_name("gaming")

    assert @view.filters_active?
    assert_equal ["Gaming"], @view.active_filter_tag_names
  end

  def test_filter_by_an_unknown_tag_name_does_nothing
    @view.filter_by_tag_name("Nonexistent")

    refute @view.filters_active?
  end

  def test_remove_filter_tag_by_name_clears_that_filter
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]
    @view.add_filter_tag(7)

    @view.remove_filter_tag_by_name("Gaming")

    refute @view.filters_active?
  end

  def test_remove_filter_tag_by_an_unknown_name_leaves_filters_alone
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]
    @view.add_filter_tag(7)

    @view.remove_filter_tag_by_name("Nonexistent")

    assert @view.filters_active?
  end

  def test_filter_state_changes_are_announced
    announced = []
    @tags = [Domain::Tag.new(id: 7, name: "Gaming")]
    @view.on_filter_state_changed = ->(active) { announced << active }

    @view.add_filter_tag(7)
    @view.clear_all_filters

    assert_equal [true, false], announced
  end

  # --- Bucket rules ---

  # ADR 001: a UI component may not hold a manager, repository or adapter.
  def test_holds_no_manager_or_repository
    collaborators = @view.instance_variables.map { |name| @view.instance_variable_get(name) }

    assert(collaborators.none? { |value| value.class.name.to_s =~ /Manager|Repository|Adapter/ })
    refute @view.respond_to?(:queue_manager),
           "UI Components must not expose a manager (ADR 001)"
  end
end
