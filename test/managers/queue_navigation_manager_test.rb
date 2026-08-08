require 'minitest/autorun'
require_relative '../../lib/managers/queue_navigation_manager'

# Stands in for Managers::QueueManager: navigation only reads the queue and
# asks for moves, so the stub records what it was asked to do.
class MockQueueManagerForNavigation
  attr_reader :moves, :removed

  def initialize(entries = [])
    @entries = entries
    @moves = []
    @removed = []
    @move_result = true
    @next_after_removal = nil
  end

  def move_result=(value)
    @move_result = value
  end

  def next_after_removal=(entry)
    @next_after_removal = entry
  end

  def all
    @entries
  end

  def find_by_url(url)
    @entries.find { |entry| entry.url == url }
  end

  def move_up(id)
    @moves << [:up, id]
    @move_result
  end

  def move_down(id)
    @moves << [:down, id]
    @move_result
  end

  def remove_by_url(url)
    @removed << url
    @next_after_removal
  end
end

class ManagersQueueNavigationManagerTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def entry(url, position)
    Domain::QueueEntry.new(url: url, added_at: ADDED_AT, id: position, position: position)
  end

  def setup
    @first = entry('https://example.com/1', 1)
    @second = entry('https://example.com/2', 2)
    @third = entry('https://example.com/3', 3)
    @queue_manager = MockQueueManagerForNavigation.new([@first, @second, @third])
    @navigation = Managers::QueueNavigationManager.new(@queue_manager)
  end

  # === next_entry / previous_entry ===

  def test_next_entry_steps_forward
    assert_equal @second, @navigation.next_entry(@first.url)
  end

  def test_next_entry_wraps_at_the_end
    assert_equal @first, @navigation.next_entry(@third.url)
  end

  def test_previous_entry_steps_back
    assert_equal @first, @navigation.previous_entry(@second.url)
  end

  def test_previous_entry_wraps_at_the_start
    assert_equal @third, @navigation.previous_entry(@first.url)
  end

  def test_traversal_from_an_unqueued_page_starts_at_the_near_end
    assert_equal @first, @navigation.next_entry('https://elsewhere.test')
    assert_equal @third, @navigation.previous_entry('https://elsewhere.test')
  end

  def test_traversal_of_an_empty_queue_goes_nowhere
    navigation = Managers::QueueNavigationManager.new(MockQueueManagerForNavigation.new([]))

    assert_nil navigation.next_entry('https://example.com/1')
    assert_nil navigation.previous_entry('https://example.com/1')
  end

  # === remove_current_and_advance ===

  def test_remove_current_and_advance_removes_the_page
    @queue_manager.next_after_removal = @second

    assert_equal @second, @navigation.remove_current_and_advance(@first.url)
    assert_equal [@first.url], @queue_manager.removed
  end

  def test_remove_current_and_advance_reports_nothing_left_to_visit
    @queue_manager.next_after_removal = nil

    assert_nil @navigation.remove_current_and_advance(@third.url)
  end

  # === move_current_up / move_current_down ===

  def test_move_current_up_moves_the_queued_entry
    assert_equal @second, @navigation.move_current_up(@second.url)
    assert_equal [[:up, @second.id]], @queue_manager.moves
  end

  def test_move_current_down_moves_the_queued_entry
    assert_equal @second, @navigation.move_current_down(@second.url)
    assert_equal [[:down, @second.id]], @queue_manager.moves
  end

  def test_move_current_reports_nothing_when_the_move_was_refused
    @queue_manager.move_result = false

    assert_nil @navigation.move_current_up(@first.url)
  end

  def test_move_current_does_nothing_for_an_unqueued_page
    assert_nil @navigation.move_current_up('https://elsewhere.test')
    assert_equal [], @queue_manager.moves
  end

  def test_move_current_does_nothing_without_a_current_url
    assert_nil @navigation.move_current_down(nil)
    assert_equal [], @queue_manager.moves
  end

  # === Preserved wart ===

  def test_moving_the_current_page_needs_an_exact_url_match
    # Known wart, preserved from BrowserWindow: unlike remove-and-advance,
    # which matches loosely, the move shortcuts look the URL up exactly. A
    # video that has gained a "&t=90s" timestamp cannot be reordered from the
    # keyboard until you navigate back to the queued URL.
    assert_nil @navigation.move_current_up("#{@first.url}?t=90s")
  end
end
