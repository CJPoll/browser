require 'minitest/autorun'
require_relative '../../lib/managers/queue_manager'
require_relative '../support/test_clock'

# Stands in for Repositories::QueueRepository, keeping entries in memory with
# the same contiguous-position guarantee the real one maintains.
class MockQueueRepository
  attr_reader :updates

  def initialize
    @entries = []
    @next_id = 1
    @updates = []
  end

  def all
    @entries.sort_by(&:position)
  end

  def first
    all.first
  end

  def count
    @entries.length
  end

  def max_position
    @entries.map(&:position).max || 0
  end

  def find_by_id(id)
    return nil if id.nil?

    @entries.find { |entry| entry.id == id }
  end

  def find_by_url(url)
    return nil if url.nil?

    @entries.find { |entry| entry.url == url }
  end

  def find_by_position(position)
    @entries.find { |entry| entry.position == position }
  end

  def find_all_by_ids(ids)
    return [] if ids.nil? || ids.empty?

    all.select { |entry| ids.include?(entry.id) }
  end

  def add(entry)
    return nil if find_by_url(entry.url)

    stored = entry.with(id: @next_id, position: @entries.length + 1)
    @next_id += 1
    @entries << stored
    stored
  end

  def remove(id)
    entry = find_by_id(id)
    return false unless entry

    @entries.delete(entry)
    @entries = @entries.map do |other|
      other.position > entry.position ? other.with(position: other.position - 1) : other
    end
    true
  end

  def move(id, new_position)
    entry = find_by_id(id)
    return false unless entry
    return true if entry.position == new_position

    target = new_position.clamp(1, max_position)
    remaining = all.reject { |other| other.id == id }
    remaining.insert(target - 1, entry)
    @entries = remaining.each_with_index.map { |other, index| other.with(position: index + 1) }
    true
  end

  def update_title(url, title)
    @updates << [:title, url, title]
  end

  def update_favicon(url, favicon_data)
    @updates << [:favicon, url, favicon_data]
  end

  def update_published_at(url, published_at)
    @updates << [:published_at, url, published_at]
  end

  def clear_all
    @entries = []
  end
end

# Stands in for Repositories::TagRepository.
class MockTagRepository
  attr_reader :created

  def initialize
    @tags = []
    @assignments = []
    @next_id = 1
    @created = []
  end

  def create_or_find(name)
    @created << name
    existing = find_by_name(name)
    return existing if existing

    tag = Domain::Tag.new(id: @next_id, name: name)
    @next_id += 1
    @tags << tag
    tag
  end

  def find_by_name(name)
    return nil if name.nil?

    @tags.find { |tag| tag.same_name?(name) }
  end

  def find_by_id(id)
    return nil if id.nil?

    @tags.find { |tag| tag.id == id }
  end

  def all
    @tags.sort_by { |tag| tag.name.downcase }
  end

  def delete(id)
    tag = find_by_id(id)
    return false unless tag

    @tags.delete(tag)
    @assignments.reject! { |pair| pair.last == id }
    true
  end

  def assign(entry_id, tag_id)
    return false if @assignments.include?([entry_id, tag_id])

    @assignments << [entry_id, tag_id]
    true
  end

  def assigned?(entry_id, tag_id)
    @assignments.include?([entry_id, tag_id])
  end

  def unassign(entry_id, tag_id)
    !@assignments.delete([entry_id, tag_id]).nil?
  end

  def tags_for_entry(entry_id)
    return [] if entry_id.nil?

    ids = @assignments.select { |pair| pair.first == entry_id }.map(&:last)
    @tags.select { |tag| ids.include?(tag.id) }.sort_by { |tag| tag.name.downcase }
  end

  def entry_ids_with_all_tags(tag_ids)
    return [] if tag_ids.nil? || tag_ids.empty?

    @assignments.map(&:first).uniq.select do |entry_id|
      assigned = @assignments.select { |pair| pair.first == entry_id }.map(&:last)
      tag_ids.all? { |tag_id| assigned.include?(tag_id) }
    end
  end

  def usage_counts
    all.map do |tag|
      Domain::TagUsage.new(tag: tag, count: @assignments.count { |pair| pair.last == tag.id })
    end
  end
end

class ManagersQueueManagerTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze
  PUBLISHED_AT = Time.at(1_600_000_000).freeze

  def setup
    @queue_repository = MockQueueRepository.new
    @tag_repository = MockTagRepository.new
    @clock = TestClock.new(NOW)
    @manager = Managers::QueueManager.new(
      queue_repository: @queue_repository,
      tag_repository: @tag_repository,
      clock: @clock
    )
  end

  # === add ===

  def test_add_stores_a_web_url
    assert_equal :added, @manager.add('https://example.com/1', 'One')
    assert_equal ['https://example.com/1'], @manager.all.map(&:url)
  end

  def test_add_stamps_the_entry_with_the_injected_clock
    @clock.advance(90)
    @manager.add('https://example.com/1')

    assert_equal Time.at(1_700_000_090), @manager.all.first.added_at
  end

  def test_add_reports_a_url_already_queued
    @manager.add('https://example.com/1')

    assert_equal :already_exists, @manager.add('https://example.com/1')
  end

  def test_add_rejects_a_non_web_url
    assert_equal :invalid_url, @manager.add('file:///home/user/notes.md')
    assert_equal 0, @manager.count
  end

  def test_add_rejects_a_nil_url
    assert_equal :invalid_url, @manager.add(nil)
  end

  def test_add_carries_the_title_and_favicon_it_is_given
    @manager.add('https://example.com/1', 'One', 'PNGDATA')
    entry = @manager.all.first

    assert_equal 'One', entry.title
    assert_equal 'PNGDATA', entry.favicon_data
  end

  # === Lookups ===

  def test_find_by_url_matches_exactly
    @manager.add('https://example.com/1')

    assert_nil @manager.find_by_url('https://example.com/1?t=90s')
  end

  def test_find_by_url_fuzzy_tolerates_an_added_parameter
    @manager.add('https://youtube.com/watch?v=abc')

    entry = @manager.find_by_url_fuzzy('https://youtube.com/watch?v=abc&t=90s')

    assert_equal 'https://youtube.com/watch?v=abc', entry.url
  end

  def test_find_by_url_fuzzy_returns_nil_for_a_different_page
    @manager.add('https://youtube.com/watch?v=abc')

    assert_nil @manager.find_by_url_fuzzy('https://youtube.com/watch?v=zzz')
  end

  def test_find_by_id_returns_the_entry
    stored = @manager.add('https://example.com/1')
    id = @manager.all.first.id

    assert_equal :added, stored
    assert_equal 'https://example.com/1', @manager.find_by_id(id).url
  end

  def test_first_is_the_front_of_the_queue
    @manager.add('https://example.com/1')
    @manager.add('https://example.com/2')

    assert_equal 'https://example.com/1', @manager.first.url
  end

  # === remove ===

  def test_remove_by_id_returns_the_entry_that_took_its_place
    @manager.add('https://example.com/1')
    @manager.add('https://example.com/2')
    first_id = @manager.all.first.id

    assert_equal 'https://example.com/2', @manager.remove_by_id(first_id).url
  end

  def test_remove_by_id_returns_nil_when_the_removed_entry_was_last
    @manager.add('https://example.com/1')

    assert_nil @manager.remove_by_id(@manager.all.first.id)
    assert_equal 0, @manager.count
  end

  def test_remove_by_id_returns_nil_for_an_unknown_id
    assert_nil @manager.remove_by_id(999)
  end

  def test_remove_by_url_matches_loosely
    @manager.add('https://youtube.com/watch?v=abc')
    @manager.add('https://example.com/2')

    next_entry = @manager.remove_by_url('https://youtube.com/watch?v=abc&t=90s')

    assert_equal 'https://example.com/2', next_entry.url
    assert_equal 1, @manager.count
  end

  def test_remove_by_url_leaves_the_queue_alone_when_the_page_is_not_queued
    @manager.add('https://example.com/1')

    assert_nil @manager.remove_by_url('https://elsewhere.test')
    assert_equal 1, @manager.count
  end

  # === Reordering ===

  def test_move_up_swaps_with_the_entry_in_front
    @manager.add('https://example.com/1')
    @manager.add('https://example.com/2')
    second_id = @manager.all.last.id

    assert @manager.move_up(second_id)
    assert_equal %w[https://example.com/2 https://example.com/1], @manager.all.map(&:url)
  end

  def test_move_up_refuses_at_the_front
    @manager.add('https://example.com/1')

    refute @manager.move_up(@manager.all.first.id)
  end

  def test_move_down_swaps_with_the_entry_behind
    @manager.add('https://example.com/1')
    @manager.add('https://example.com/2')
    first_id = @manager.all.first.id

    assert @manager.move_down(first_id)
    assert_equal %w[https://example.com/2 https://example.com/1], @manager.all.map(&:url)
  end

  def test_move_down_refuses_at_the_back
    @manager.add('https://example.com/1')

    refute @manager.move_down(@manager.all.first.id)
  end

  def test_moving_an_unknown_entry_reports_false
    refute @manager.move_up(999)
    refute @manager.move_down(999)
  end

  # === Metadata updates ===

  def test_update_title_reaches_the_repository
    @manager.update_title('https://example.com/1', 'Fetched')

    assert_includes @queue_repository.updates, [:title, 'https://example.com/1', 'Fetched']
  end

  def test_update_title_ignores_a_missing_title
    @manager.update_title('https://example.com/1', nil)

    assert_equal [], @queue_repository.updates
  end

  def test_update_favicon_ignores_missing_bytes
    @manager.update_favicon('https://example.com/1', nil)

    assert_equal [], @queue_repository.updates
  end

  def test_update_published_at_reaches_the_repository
    @manager.update_published_at('https://example.com/1', PUBLISHED_AT)

    assert_includes @queue_repository.updates,
                    [:published_at, 'https://example.com/1', PUBLISHED_AT]
  end

  def test_update_published_at_ignores_a_missing_date
    @manager.update_published_at('https://example.com/1', nil)

    assert_equal [], @queue_repository.updates
  end

  # === Tags ===

  def test_create_or_find_tag_normalizes_the_name
    tag = @manager.create_or_find_tag('  read   later  ')

    assert_equal 'read later', tag.name
    assert_equal ['read later'], @tag_repository.created
  end

  def test_create_or_find_tag_returns_the_existing_tag
    first = @manager.create_or_find_tag('Gaming')

    assert_equal first, @manager.create_or_find_tag('gaming')
  end

  def test_create_or_find_tag_rejects_a_blank_name
    assert_nil @manager.create_or_find_tag('   ')
    assert_equal [], @tag_repository.created
  end

  def test_create_or_find_tag_accepts_a_name_at_the_length_limit
    refute_nil @manager.create_or_find_tag('a' * 100)
  end

  def test_create_or_find_tag_rejects_an_over_long_name
    assert_nil @manager.create_or_find_tag('a' * 101)
    assert_equal [], @tag_repository.created
  end

  def test_create_or_find_tag_measures_length_after_normalizing
    # Whitespace collapse can bring an over-long name under the limit
    refute_nil @manager.create_or_find_tag("#{'a' * 50}    #{'b' * 49}")
  end

  def test_create_or_find_tag_rejects_nil
    assert_nil @manager.create_or_find_tag(nil)
  end

  def test_find_tag_by_name_normalizes_before_looking_up
    @manager.create_or_find_tag('read later')

    refute_nil @manager.find_tag_by_name('  READ   LATER  ')
  end

  def test_find_tag_by_name_returns_nil_for_a_blank_name
    assert_nil @manager.find_tag_by_name('   ')
  end

  def test_all_tags_is_alphabetical
    %w[zebra Alpha gamma].each { |name| @manager.create_or_find_tag(name) }

    assert_equal %w[Alpha gamma zebra], @manager.all_tags.map(&:name)
  end

  # === Assignment ===

  def test_assign_tag_links_an_entry_and_a_tag
    entry_id = queued_entry_id
    tag = @manager.create_or_find_tag('Gaming')

    assert_equal :assigned, @manager.assign_tag(entry_id, tag.id)
    assert_equal ['Gaming'], @manager.tags_for_entry(entry_id).map(&:name)
  end

  def test_assign_tag_is_idempotent
    entry_id = queued_entry_id
    tag = @manager.create_or_find_tag('Gaming')
    @manager.assign_tag(entry_id, tag.id)

    assert_equal :already_assigned, @manager.assign_tag(entry_id, tag.id)
  end

  def test_assign_tag_rejects_an_unknown_entry
    tag = @manager.create_or_find_tag('Gaming')

    assert_equal :invalid_entry, @manager.assign_tag(999, tag.id)
  end

  def test_assign_tag_rejects_an_unknown_tag
    assert_equal :invalid_tag, @manager.assign_tag(queued_entry_id, 999)
  end

  def test_assign_tag_rejects_nil_ids
    assert_equal :invalid_params, @manager.assign_tag(nil, 1)
    assert_equal :invalid_params, @manager.assign_tag(1, nil)
  end

  def test_unassign_tag_removes_the_link
    entry_id = queued_entry_id
    tag = @manager.create_or_find_tag('Gaming')
    @manager.assign_tag(entry_id, tag.id)

    assert_equal :unassigned, @manager.unassign_tag(entry_id, tag.id)
    assert_equal [], @manager.tags_for_entry(entry_id)
  end

  def test_unassign_tag_reports_a_link_that_was_not_there
    entry_id = queued_entry_id
    tag = @manager.create_or_find_tag('Gaming')

    assert_equal :not_assigned, @manager.unassign_tag(entry_id, tag.id)
  end

  def test_unassign_tag_rejects_nil_ids
    assert_equal :invalid_params, @manager.unassign_tag(nil, 1)
    assert_equal :invalid_params, @manager.unassign_tag(1, nil)
  end

  def test_assign_tag_by_name_creates_the_tag
    entry_id = queued_entry_id

    assert_equal :assigned, @manager.assign_tag_by_name(entry_id, 'YouTube')
    assert_equal ['YouTube'], @manager.tags_for_entry(entry_id).map(&:name)
  end

  def test_assign_tag_by_name_reuses_an_existing_tag_ignoring_case
    entry_id = queued_entry_id
    @manager.assign_tag_by_name(entry_id, 'YouTube')

    assert_equal :already_assigned, @manager.assign_tag_by_name(entry_id, 'youtube')
  end

  def test_assign_tag_by_name_rejects_a_blank_name
    assert_equal :invalid_params, @manager.assign_tag_by_name(queued_entry_id, '   ')
  end

  def test_assign_tag_by_name_rejects_a_nil_entry
    assert_equal :invalid_params, @manager.assign_tag_by_name(nil, 'YouTube')
  end

  def test_unassign_tag_by_name_removes_the_link
    entry_id = queued_entry_id
    @manager.assign_tag_by_name(entry_id, 'YouTube')

    assert_equal :unassigned, @manager.unassign_tag_by_name(entry_id, 'youtube')
  end

  def test_unassign_tag_by_name_reports_an_unknown_tag
    assert_equal :not_assigned, @manager.unassign_tag_by_name(queued_entry_id, 'Nonexistent')
  end

  def test_unassign_tag_by_name_rejects_a_blank_name
    assert_equal :invalid_params, @manager.unassign_tag_by_name(queued_entry_id, '  ')
  end

  # === Tag queries ===

  def test_entries_with_tag_returns_carriers_in_queue_order
    first = queued_entry_id('https://example.com/1')
    second = queued_entry_id('https://example.com/2')
    tag = @manager.create_or_find_tag('Gaming')
    @manager.assign_tag(second, tag.id)
    @manager.assign_tag(first, tag.id)

    assert_equal %w[https://example.com/1 https://example.com/2],
                 @manager.entries_with_tag(tag.id).map(&:url)
  end

  def test_entries_with_tags_requires_every_tag
    tagged_twice = queued_entry_id('https://example.com/1')
    tagged_once = queued_entry_id('https://example.com/2')
    gaming = @manager.create_or_find_tag('Gaming')
    tutorial = @manager.create_or_find_tag('Tutorial')
    @manager.assign_tag(tagged_twice, gaming.id)
    @manager.assign_tag(tagged_twice, tutorial.id)
    @manager.assign_tag(tagged_once, gaming.id)

    assert_equal %w[https://example.com/1],
                 @manager.entries_with_tags([gaming.id, tutorial.id]).map(&:url)
  end

  def test_entries_with_tags_is_empty_for_no_tags
    queued_entry_id

    assert_equal [], @manager.entries_with_tags([])
  end

  def test_entries_with_tag_is_empty_for_a_nil_tag
    assert_equal [], @manager.entries_with_tag(nil)
  end

  def test_entries_for_filter_returns_everything_when_no_tags_are_selected
    queued_entry_id('https://example.com/1')
    queued_entry_id('https://example.com/2')

    assert_equal %w[https://example.com/1 https://example.com/2],
                 @manager.entries_for_filter([]).map(&:url)
  end

  def test_entries_for_filter_returns_everything_for_a_nil_filter
    queued_entry_id('https://example.com/1')

    assert_equal %w[https://example.com/1], @manager.entries_for_filter(nil).map(&:url)
  end

  def test_entries_for_filter_narrows_to_carriers_of_every_selected_tag
    tagged = queued_entry_id('https://example.com/1')
    queued_entry_id('https://example.com/2')
    gaming = @manager.create_or_find_tag('Gaming')
    @manager.assign_tag(tagged, gaming.id)

    assert_equal %w[https://example.com/1], @manager.entries_for_filter([gaming.id]).map(&:url)
  end

  def test_entries_for_filter_is_empty_when_nothing_carries_the_tag
    queued_entry_id('https://example.com/1')
    orphan = @manager.create_or_find_tag('Orphan')

    assert_equal [], @manager.entries_for_filter([orphan.id])
  end

  def test_tag_usage_counts_reports_carriers
    entry_id = queued_entry_id
    @manager.assign_tag_by_name(entry_id, 'Gaming')
    @manager.create_or_find_tag('Orphan')

    counts = @manager.tag_usage_counts.map { |usage| [usage.name, usage.count] }

    assert_equal [['Gaming', 1], ['Orphan', 0]], counts
  end

  def test_delete_tag_removes_it
    tag = @manager.create_or_find_tag('Gaming')

    assert_equal :deleted, @manager.delete_tag(tag.id)
    assert_equal [], @manager.all_tags
  end

  def test_delete_tag_reports_an_unknown_tag
    assert_equal :not_found, @manager.delete_tag(999)
  end

  def test_delete_tag_rejects_nil
    assert_equal :invalid_params, @manager.delete_tag(nil)
  end

  # === clear_all ===

  def test_clear_all_empties_the_queue
    queued_entry_id

    @manager.clear_all

    assert_equal 0, @manager.count
  end

  private

  def queued_entry_id(url = 'https://example.com/queued')
    @manager.add(url)
    @manager.find_by_url(url).id
  end
end
