require 'minitest/autorun'
require_relative '../../lib/domain/queue_entry'
require_relative '../../lib/domain/queue_traversal'

class DomainQueueTraversalTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def entry(url, position)
    Domain::QueueEntry.new(url: url, added_at: ADDED_AT, id: position, position: position)
  end

  def setup
    @first = entry('https://example.com/1', 1)
    @second = entry('https://example.com/2', 2)
    @third = entry('https://example.com/3', 3)
    @queue = [@first, @second, @third]
  end

  # === next_after ===

  def test_next_after_returns_the_following_entry
    assert_equal @second, Domain::QueueTraversal.next_after(@queue, @first.url)
  end

  def test_next_after_wraps_from_the_last_entry_to_the_first
    assert_equal @first, Domain::QueueTraversal.next_after(@queue, @third.url)
  end

  def test_next_after_starts_at_the_first_entry_when_the_url_is_not_queued
    assert_equal @first, Domain::QueueTraversal.next_after(@queue, 'https://elsewhere.test')
  end

  def test_next_after_starts_at_the_first_entry_when_there_is_no_current_url
    assert_equal @first, Domain::QueueTraversal.next_after(@queue, nil)
  end

  def test_next_after_returns_nil_for_an_empty_queue
    assert_nil Domain::QueueTraversal.next_after([], @first.url)
  end

  def test_next_after_returns_nil_for_a_missing_queue
    assert_nil Domain::QueueTraversal.next_after(nil, @first.url)
  end

  def test_next_after_a_single_entry_is_itself
    assert_equal @first, Domain::QueueTraversal.next_after([@first], @first.url)
  end

  # === previous_before ===

  def test_previous_before_returns_the_preceding_entry
    assert_equal @second, Domain::QueueTraversal.previous_before(@queue, @third.url)
  end

  def test_previous_before_wraps_from_the_first_entry_to_the_last
    assert_equal @third, Domain::QueueTraversal.previous_before(@queue, @first.url)
  end

  def test_previous_before_starts_at_the_last_entry_when_the_url_is_not_queued
    assert_equal @third, Domain::QueueTraversal.previous_before(@queue, 'https://elsewhere.test')
  end

  def test_previous_before_starts_at_the_last_entry_when_there_is_no_current_url
    assert_equal @third, Domain::QueueTraversal.previous_before(@queue, nil)
  end

  def test_previous_before_returns_nil_for_an_empty_queue
    assert_nil Domain::QueueTraversal.previous_before([], @first.url)
  end

  def test_previous_before_returns_nil_for_a_missing_queue
    assert_nil Domain::QueueTraversal.previous_before(nil, @first.url)
  end

  def test_previous_before_a_single_entry_is_itself
    assert_equal @first, Domain::QueueTraversal.previous_before([@first], @first.url)
  end

  # === index_of ===

  def test_index_of_finds_the_position_in_the_list
    assert_equal 1, Domain::QueueTraversal.index_of(@queue, @second.url)
  end

  def test_index_of_returns_nil_for_a_url_that_is_not_queued
    assert_nil Domain::QueueTraversal.index_of(@queue, 'https://elsewhere.test')
  end

  def test_index_of_returns_nil_for_no_current_url
    assert_nil Domain::QueueTraversal.index_of(@queue, nil)
  end

  # === Preserved wart ===

  def test_matching_is_exact_so_an_added_parameter_restarts_traversal
    # Known wart, preserved from BrowserWindow: traversal compares URLs
    # exactly rather than with Domain::UrlMatcher, so a YouTube page that has
    # gained a "&t=90s" timestamp counts as not being in the queue and the
    # next item is the first, not the second.
    playing = "#{@first.url}?t=90s"

    assert_equal @first, Domain::QueueTraversal.next_after(@queue, playing)
    assert_equal @third, Domain::QueueTraversal.previous_before(@queue, playing)
  end
end
