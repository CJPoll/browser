require 'minitest/autorun'
require_relative '../../lib/domain/queue_sort'
require_relative '../../lib/domain/queue_entry'

# Exhaustive tests for the queue sidebar's sort policy
class QueueSortTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def build_entry(title:, position:, published_at: nil)
    Domain::QueueEntry.new(
      url: "https://example.com/#{position}",
      title: title,
      position: position,
      published_at: published_at,
      added_at: ADDED_AT
    )
  end

  def titles(entries)
    entries.map(&:display_title)
  end

  # ============================================================
  # :position -- the order the repository already returned
  # ============================================================

  def test_position_mode_preserves_the_given_order
    entries = [
      build_entry(title: "Zebra", position: 1),
      build_entry(title: "Alpha", position: 2)
    ]

    assert_equal ["Zebra", "Alpha"], titles(Domain::QueueSort.apply(entries, :position))
  end

  def test_position_mode_returns_the_same_array_object
    entries = [build_entry(title: "Only", position: 1)]

    assert_same entries, Domain::QueueSort.apply(entries, :position)
  end

  # ============================================================
  # :title -- case-insensitive alphabetical
  # ============================================================

  def test_title_mode_sorts_alphabetically
    entries = [
      build_entry(title: "Zebra", position: 1),
      build_entry(title: "Alpha", position: 2),
      build_entry(title: "Middle", position: 3)
    ]

    assert_equal ["Alpha", "Middle", "Zebra"], titles(Domain::QueueSort.apply(entries, :title))
  end

  def test_title_mode_is_case_insensitive
    entries = [
      build_entry(title: "beta", position: 1),
      build_entry(title: "Alpha", position: 2),
      build_entry(title: "aardvark", position: 3)
    ]

    assert_equal ["aardvark", "Alpha", "beta"], titles(Domain::QueueSort.apply(entries, :title))
  end

  def test_title_mode_falls_back_to_the_url_for_untitled_entries
    untitled = Domain::QueueEntry.new(url: "https://aaa.example.com", added_at: ADDED_AT, position: 1)
    titled = build_entry(title: "Zebra", position: 2)

    sorted = Domain::QueueSort.apply([titled, untitled], :title)

    assert_equal ["https://aaa.example.com", "Zebra"], titles(sorted)
  end

  def test_title_mode_does_not_mutate_the_input
    entries = [
      build_entry(title: "Zebra", position: 1),
      build_entry(title: "Alpha", position: 2)
    ]

    Domain::QueueSort.apply(entries, :title)

    assert_equal ["Zebra", "Alpha"], titles(entries)
  end

  # ============================================================
  # :date_published -- newest first, unknown dates last
  # ============================================================

  def test_date_published_mode_sorts_newest_first
    older = build_entry(title: "Older", position: 1, published_at: Time.at(1_704_067_200))
    newer = build_entry(title: "Newer", position: 2, published_at: Time.at(1_717_200_000))

    assert_equal ["Newer", "Older"], titles(Domain::QueueSort.apply([older, newer], :date_published))
  end

  def test_date_published_mode_puts_entries_without_a_date_last
    dated = build_entry(title: "Dated", position: 1, published_at: Time.at(1_704_067_200))
    undated = build_entry(title: "Undated", position: 2)

    assert_equal ["Dated", "Undated"], titles(Domain::QueueSort.apply([undated, dated], :date_published))
  end

  def test_date_published_mode_keeps_undated_entries_together
    undated_a = build_entry(title: "A", position: 1)
    undated_b = build_entry(title: "B", position: 2)
    dated = build_entry(title: "Dated", position: 3, published_at: Time.at(1_704_067_200))

    sorted = Domain::QueueSort.apply([undated_a, undated_b, dated], :date_published)

    assert_equal ["Dated", "A", "B"], titles(sorted)
  end

  def test_date_published_mode_with_no_dates_at_all_keeps_the_given_order
    entries = [
      build_entry(title: "First", position: 1),
      build_entry(title: "Second", position: 2)
    ]

    assert_equal ["First", "Second"], titles(Domain::QueueSort.apply(entries, :date_published))
  end

  # ============================================================
  # Edge cases
  # ============================================================

  def test_empty_queue_sorts_to_empty
    Domain::QueueSort::MODES.each do |mode|
      assert_empty Domain::QueueSort.apply([], mode), "mode #{mode} should handle an empty queue"
    end
  end

  def test_unknown_mode_leaves_the_order_alone
    entries = [
      build_entry(title: "Zebra", position: 1),
      build_entry(title: "Alpha", position: 2)
    ]

    assert_equal ["Zebra", "Alpha"], titles(Domain::QueueSort.apply(entries, :nonsense))
  end

  def test_modes_lists_every_supported_mode
    assert_equal [:position, :title, :date_published], Domain::QueueSort::MODES
  end
end
