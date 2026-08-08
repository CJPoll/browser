require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/queue_database'
require_relative '../../lib/repositories/queue_repository'
require_relative '../../lib/repositories/tag_repository'

# Repositories are never mocked -- these run against a real SQLite file.
# Queue entries are created through QueueRepository because the assignments
# table has a foreign key onto them.
class TagRepositoryTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze

  def setup
    @db_path = "/tmp/test_tag_repository_#{Process.pid}.db"
    FileUtils.rm_f(@db_path)
    @database = Repositories::QueueDatabase.new(db_path: @db_path)
    @queue_repository = Repositories::QueueRepository.new(@database)
    @repository = Repositories::TagRepository.new(@database)
    @entry = add_entry('https://example.com/1')
  end

  def teardown
    @database&.close
    FileUtils.rm_f(@db_path)
  end

  def add_entry(url)
    @queue_repository.add(Domain::QueueEntry.new(url: url, added_at: ADDED_AT))
  end

  # === Schema ===

  def test_uses_the_pre_existing_tags_table
    @repository.create_or_find('Gaming')

    assert_equal [{ 'name' => 'Gaming' }], @database.execute('SELECT name FROM tags')
  end

  def test_uses_the_pre_existing_assignments_table
    tag = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, tag.id)

    rows = @database.execute('SELECT queue_entry_id, tag_id FROM queue_entry_tag_assignments')

    assert_equal [{ 'queue_entry_id' => @entry.id, 'tag_id' => tag.id }], rows
  end

  def test_tags_survive_reconnection
    @repository.create_or_find('Gaming')
    @database.close

    reopened = Repositories::QueueDatabase.new(db_path: @db_path)
    begin
      assert_equal ['Gaming'], Repositories::TagRepository.new(reopened).all.map(&:name)
    ensure
      reopened.close
    end
  end

  # === create_or_find ===

  def test_create_or_find_creates_a_tag_with_an_id
    tag = @repository.create_or_find('Gaming')

    refute_nil tag.id
    assert_equal 'Gaming', tag.name
  end

  def test_create_or_find_returns_the_existing_tag
    first = @repository.create_or_find('Gaming')
    second = @repository.create_or_find('Gaming')

    assert_equal first, second
    assert_equal 1, @repository.all.length
  end

  def test_create_or_find_matches_case_insensitively
    first = @repository.create_or_find('YouTube')
    second = @repository.create_or_find('youtube')

    assert_equal first.id, second.id
  end

  def test_create_or_find_keeps_the_spelling_written_first
    @repository.create_or_find('YouTube')

    assert_equal 'YouTube', @repository.create_or_find('youtube').name
  end

  def test_create_or_find_returns_nil_for_a_nil_name
    assert_nil @repository.create_or_find(nil)
  end

  def test_create_or_find_returns_nil_when_the_length_check_rejects_the_name
    # Backstop only: the manager validates length before calling
    assert_nil @repository.create_or_find('a' * 101)
  end

  # === Lookups ===

  def test_find_by_name_matches_case_insensitively
    created = @repository.create_or_find('YouTube')

    assert_equal created, @repository.find_by_name('YOUTUBE')
  end

  def test_find_by_name_returns_nil_for_an_unknown_name
    assert_nil @repository.find_by_name('Nonexistent')
  end

  def test_find_by_name_returns_nil_for_a_nil_name
    assert_nil @repository.find_by_name(nil)
  end

  def test_find_by_id_returns_the_tag
    created = @repository.create_or_find('Gaming')

    assert_equal created, @repository.find_by_id(created.id)
  end

  def test_find_by_id_returns_nil_for_an_unknown_id
    assert_nil @repository.find_by_id(999)
  end

  def test_find_by_id_returns_nil_for_a_nil_id
    assert_nil @repository.find_by_id(nil)
  end

  def test_all_is_empty_for_a_new_database
    assert_equal [], @repository.all
  end

  def test_all_is_alphabetical_ignoring_case
    %w[zebra Alpha gamma].each { |name| @repository.create_or_find(name) }

    assert_equal %w[Alpha gamma zebra], @repository.all.map(&:name)
  end

  # === delete ===

  def test_delete_removes_the_tag
    tag = @repository.create_or_find('Gaming')

    assert @repository.delete(tag.id)
    assert_equal [], @repository.all
  end

  def test_delete_cascades_to_assignments
    tag = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, tag.id)

    @repository.delete(tag.id)

    assert_equal [], @repository.tags_for_entry(@entry.id)
  end

  def test_delete_reports_false_for_an_unknown_tag
    refute @repository.delete(999)
  end

  def test_delete_reports_false_for_a_nil_id
    refute @repository.delete(nil)
  end

  # === assign / unassign ===

  def test_assign_creates_the_assignment
    tag = @repository.create_or_find('Gaming')

    assert @repository.assign(@entry.id, tag.id)
    assert_equal [tag], @repository.tags_for_entry(@entry.id)
  end

  def test_assign_reports_false_when_already_assigned
    tag = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, tag.id)

    refute @repository.assign(@entry.id, tag.id)
  end

  def test_assign_twice_leaves_one_assignment
    tag = @repository.create_or_find('Gaming')
    2.times { @repository.assign(@entry.id, tag.id) }

    assert_equal 1, @repository.tags_for_entry(@entry.id).length
  end

  def test_assigned_reports_the_assignment
    tag = @repository.create_or_find('Gaming')

    refute @repository.assigned?(@entry.id, tag.id)
    @repository.assign(@entry.id, tag.id)
    assert @repository.assigned?(@entry.id, tag.id)
  end

  def test_unassign_removes_the_assignment
    tag = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, tag.id)

    assert @repository.unassign(@entry.id, tag.id)
    assert_equal [], @repository.tags_for_entry(@entry.id)
  end

  def test_unassign_reports_false_when_not_assigned
    tag = @repository.create_or_find('Gaming')

    refute @repository.unassign(@entry.id, tag.id)
  end

  def test_removing_an_entry_cascades_to_its_assignments
    tag = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, tag.id)

    @queue_repository.remove(@entry.id)

    assert_equal [], @repository.entry_ids_with_all_tags([tag.id])
  end

  # === tags_for_entry ===

  def test_tags_for_entry_is_alphabetical_ignoring_case
    %w[zebra Alpha gamma].each do |name|
      @repository.assign(@entry.id, @repository.create_or_find(name).id)
    end

    assert_equal %w[Alpha gamma zebra], @repository.tags_for_entry(@entry.id).map(&:name)
  end

  def test_tags_for_entry_is_empty_for_an_untagged_entry
    assert_equal [], @repository.tags_for_entry(@entry.id)
  end

  def test_tags_for_entry_is_empty_for_an_unknown_entry
    assert_equal [], @repository.tags_for_entry(999)
  end

  def test_tags_for_entry_is_empty_for_a_nil_entry
    assert_equal [], @repository.tags_for_entry(nil)
  end

  # === entry_ids_with_all_tags ===

  def test_entry_ids_with_all_tags_requires_every_tag
    other = add_entry('https://example.com/2')
    gaming = @repository.create_or_find('Gaming')
    tutorial = @repository.create_or_find('Tutorial')

    @repository.assign(@entry.id, gaming.id)
    @repository.assign(@entry.id, tutorial.id)
    @repository.assign(other.id, gaming.id)

    assert_equal [@entry.id], @repository.entry_ids_with_all_tags([gaming.id, tutorial.id])
  end

  def test_entry_ids_with_a_single_tag_returns_every_carrier
    other = add_entry('https://example.com/2')
    gaming = @repository.create_or_find('Gaming')
    @repository.assign(@entry.id, gaming.id)
    @repository.assign(other.id, gaming.id)

    assert_equal [@entry.id, other.id].sort,
                 @repository.entry_ids_with_all_tags([gaming.id]).sort
  end

  def test_entry_ids_with_all_tags_is_empty_for_no_tags
    assert_equal [], @repository.entry_ids_with_all_tags([])
  end

  def test_entry_ids_with_all_tags_is_empty_for_nil
    assert_equal [], @repository.entry_ids_with_all_tags(nil)
  end

  def test_entry_ids_with_all_tags_is_empty_when_nothing_carries_them
    gaming = @repository.create_or_find('Gaming')

    assert_equal [], @repository.entry_ids_with_all_tags([gaming.id])
  end

  # === usage_counts ===

  def test_usage_counts_reports_carriers_per_tag
    other = add_entry('https://example.com/2')
    gaming = @repository.create_or_find('Gaming')
    tutorial = @repository.create_or_find('Tutorial')

    @repository.assign(@entry.id, gaming.id)
    @repository.assign(other.id, gaming.id)
    @repository.assign(other.id, tutorial.id)

    counts = @repository.usage_counts.map { |usage| [usage.name, usage.count] }

    assert_equal [['Gaming', 2], ['Tutorial', 1]], counts
  end

  def test_usage_counts_includes_tags_carried_by_nothing
    @repository.create_or_find('Orphan')

    assert_equal [['Orphan', 0]], @repository.usage_counts.map { |u| [u.name, u.count] }
  end

  def test_usage_counts_is_alphabetical_ignoring_case
    %w[zebra Alpha gamma].each { |name| @repository.create_or_find(name) }

    assert_equal %w[Alpha gamma zebra], @repository.usage_counts.map(&:name)
  end

  def test_usage_counts_is_empty_without_tags
    assert_equal [], @repository.usage_counts
  end

  def test_usage_counts_carry_the_tag_id_for_filtering
    gaming = @repository.create_or_find('Gaming')

    assert_equal gaming.id, @repository.usage_counts.first.tag_id
  end
end
