require 'minitest/autorun'
require_relative '../../lib/domain/tag'
require_relative '../../lib/domain/tag_usage'

class DomainTagUsageTest < Minitest::Test
  GAMING = Domain::Tag.new(id: 1, name: 'Gaming').freeze

  def test_requires_a_tag
    error = assert_raises(ArgumentError) { Domain::TagUsage.new(tag: nil, count: 0) }
    assert_equal 'tag is required', error.message
  end

  def test_requires_a_count
    error = assert_raises(ArgumentError) { Domain::TagUsage.new(tag: GAMING, count: nil) }
    assert_equal 'count is required', error.message
  end

  def test_exposes_the_tag_and_count
    usage = Domain::TagUsage.new(tag: GAMING, count: 8)

    assert_equal GAMING, usage.tag
    assert_equal 8, usage.count
  end

  def test_allows_a_zero_count
    # A tag assigned to nothing still appears in the filter popover
    assert_equal 0, Domain::TagUsage.new(tag: GAMING, count: 0).count
  end

  def test_is_frozen
    assert Domain::TagUsage.new(tag: GAMING, count: 1).frozen?
  end

  # === Display shortcuts ===

  def test_name_delegates_to_the_tag
    assert_equal 'Gaming', Domain::TagUsage.new(tag: GAMING, count: 1).name
  end

  def test_tag_id_delegates_to_the_tag
    assert_equal 1, Domain::TagUsage.new(tag: GAMING, count: 1).tag_id
  end

  # === Value semantics ===

  def test_usages_with_the_same_attributes_are_equal
    assert_equal Domain::TagUsage.new(tag: GAMING, count: 3),
                 Domain::TagUsage.new(tag: GAMING, count: 3)
  end

  def test_usages_differing_in_count_are_not_equal
    refute_equal Domain::TagUsage.new(tag: GAMING, count: 3),
                 Domain::TagUsage.new(tag: GAMING, count: 4)
  end

  def test_usages_differing_in_tag_are_not_equal
    other = Domain::Tag.new(id: 2, name: 'Tutorial')

    refute_equal Domain::TagUsage.new(tag: GAMING, count: 3),
                 Domain::TagUsage.new(tag: other, count: 3)
  end

  def test_is_not_equal_to_a_lookalike_hash
    refute_equal Domain::TagUsage.new(tag: GAMING, count: 3), { tag: GAMING, count: 3 }
  end
end
