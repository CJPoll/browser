require 'minitest/autorun'
require_relative '../../lib/domain/session_snapshot'

class DomainSessionSnapshotTest < Minitest::Test
  A = 'https://a.example'.freeze
  B = 'https://b.example'.freeze
  C = 'https://c.example'.freeze

  # === Construction ===

  def test_requires_tab_urls
    error = assert_raises(ArgumentError) { Domain::SessionSnapshot.new(tab_urls: nil, current_tab_index: 0) }
    assert_equal 'tab_urls is required', error.message
  end

  def test_is_frozen
    assert Domain::SessionSnapshot.new(tab_urls: [A], current_tab_index: 0).frozen?
  end

  def test_exposes_its_tabs_and_selection
    snapshot = Domain::SessionSnapshot.new(tab_urls: [A, B], current_tab_index: 1)

    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  def test_reports_whether_it_has_any_tabs
    refute Domain::SessionSnapshot.new(tab_urls: [A], current_tab_index: 0).empty?
    assert Domain::SessionSnapshot.new(tab_urls: [], current_tab_index: 0).empty?
  end

  # === build: what gets saved ===

  def test_build_keeps_every_tab_that_has_a_url
    snapshot = Domain::SessionSnapshot.build([A, B, C], 1)

    assert_equal [A, B, C], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  # A tab that never finished loading has no URI. It used to be saved as
  # "https://www.google.com", which restored a page the user never opened.
  def test_build_drops_tabs_with_no_uri
    assert_equal [A, C], Domain::SessionSnapshot.build([A, nil, C], 0).tab_urls
  end

  def test_build_drops_tabs_with_a_blank_uri
    assert_equal [A, C], Domain::SessionSnapshot.build([A, '   ', C], 0).tab_urls
  end

  def test_build_moves_the_selection_left_past_dropped_tabs
    # The user is on C (index 2); the URI-less tab before it disappears.
    assert_equal 1, Domain::SessionSnapshot.build([A, nil, C], 2).current_tab_index
  end

  def test_build_keeps_the_selection_when_nothing_is_dropped
    assert_equal 2, Domain::SessionSnapshot.build([A, B, C], 2).current_tab_index
  end

  def test_build_selects_the_following_tab_when_the_current_one_is_dropped
    assert_equal 1, Domain::SessionSnapshot.build([A, nil, C], 1).current_tab_index
  end

  def test_build_clamps_the_selection_when_the_last_tab_is_dropped
    assert_equal 0, Domain::SessionSnapshot.build([A, nil], 1).current_tab_index
  end

  def test_build_treats_a_missing_selection_as_the_first_tab
    assert_equal 0, Domain::SessionSnapshot.build([A, B], nil).current_tab_index
  end

  def test_build_of_an_empty_window_is_empty
    snapshot = Domain::SessionSnapshot.build([], 0)

    assert snapshot.empty?
    assert_equal 0, snapshot.current_tab_index
  end

  def test_build_of_tabs_that_all_lack_uris_is_empty
    assert Domain::SessionSnapshot.build([nil, nil], 1).empty?
  end

  # === to_h / from_h: the on-disk shape ===

  def test_to_h_uses_the_session_file_keys
    snapshot = Domain::SessionSnapshot.new(tab_urls: [A, B], current_tab_index: 1)

    assert_equal({ 'tabs' => [A, B], 'current_tab_index' => 1 }, snapshot.to_h)
  end

  def test_from_h_reads_a_saved_session
    snapshot = Domain::SessionSnapshot.from_h('tabs' => [A, B], 'current_tab_index' => 1)

    assert_equal [A, B], snapshot.tab_urls
    assert_equal 1, snapshot.current_tab_index
  end

  def test_from_h_round_trips_a_snapshot
    snapshot = Domain::SessionSnapshot.new(tab_urls: [A, B], current_tab_index: 1)

    assert_equal snapshot, Domain::SessionSnapshot.from_h(snapshot.to_h)
  end

  def test_from_h_of_nil_is_no_session
    assert_nil Domain::SessionSnapshot.from_h(nil)
  end

  def test_from_h_of_a_session_with_no_tabs_is_no_session
    assert_nil Domain::SessionSnapshot.from_h('tabs' => [], 'current_tab_index' => 0)
  end

  def test_from_h_of_a_session_missing_its_tabs_key_is_no_session
    assert_nil Domain::SessionSnapshot.from_h('current_tab_index' => 0)
  end

  def test_from_h_drops_blank_entries_written_by_an_older_version
    assert_equal [A], Domain::SessionSnapshot.from_h('tabs' => [A, '', nil], 'current_tab_index' => 0).tab_urls
  end

  def test_from_h_clamps_a_selection_past_the_end
    assert_equal 1, Domain::SessionSnapshot.from_h('tabs' => [A, B], 'current_tab_index' => 9).current_tab_index
  end

  def test_from_h_treats_a_missing_selection_as_the_first_tab
    assert_equal 0, Domain::SessionSnapshot.from_h('tabs' => [A, B]).current_tab_index
  end

  def test_from_h_treats_a_nonsense_selection_as_the_first_tab
    assert_equal 0, Domain::SessionSnapshot.from_h('tabs' => [A, B], 'current_tab_index' => -3).current_tab_index
    assert_equal 0, Domain::SessionSnapshot.from_h('tabs' => [A, B], 'current_tab_index' => 'x').current_tab_index
  end

  # === Value semantics ===

  def test_snapshots_with_the_same_attributes_are_equal
    assert_equal Domain::SessionSnapshot.new(tab_urls: [A], current_tab_index: 0),
                 Domain::SessionSnapshot.new(tab_urls: [A], current_tab_index: 0)
  end

  def test_snapshots_differing_in_selection_are_not_equal
    refute_equal Domain::SessionSnapshot.new(tab_urls: [A, B], current_tab_index: 0),
                 Domain::SessionSnapshot.new(tab_urls: [A, B], current_tab_index: 1)
  end

  def test_is_not_equal_to_a_lookalike_hash
    refute_equal Domain::SessionSnapshot.new(tab_urls: [A], current_tab_index: 0),
                 { 'tabs' => [A], 'current_tab_index' => 0 }
  end
end
