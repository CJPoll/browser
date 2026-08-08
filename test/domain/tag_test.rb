require 'minitest/autorun'
require_relative '../../lib/domain/tag'

class DomainTagTest < Minitest::Test
  def test_requires_a_name
    error = assert_raises(ArgumentError) { Domain::Tag.new(name: nil) }
    assert_equal 'name is required', error.message
  end

  def test_rejects_an_empty_name
    assert_raises(ArgumentError) { Domain::Tag.new(name: '') }
  end

  def test_id_defaults_to_nil
    assert_nil Domain::Tag.new(name: 'Gaming').id
  end

  def test_exposes_name_and_id
    tag = Domain::Tag.new(id: 3, name: 'Gaming')

    assert_equal 3, tag.id
    assert_equal 'Gaming', tag.name
  end

  def test_is_frozen
    assert Domain::Tag.new(name: 'Gaming').frozen?
  end

  def test_preserves_the_case_it_was_given
    assert_equal 'YouTube', Domain::Tag.new(name: 'YouTube').name
  end

  # === same_name? ===

  def test_same_name_matches_exactly
    assert Domain::Tag.new(name: 'Gaming').same_name?('Gaming')
  end

  def test_same_name_ignores_case
    assert Domain::Tag.new(name: 'YouTube').same_name?('youtube')
    assert Domain::Tag.new(name: 'youtube').same_name?('YOUTUBE')
  end

  def test_same_name_rejects_a_different_name
    refute Domain::Tag.new(name: 'Gaming').same_name?('Tutorial')
  end

  def test_same_name_rejects_nil
    refute Domain::Tag.new(name: 'Gaming').same_name?(nil)
  end

  def test_same_name_does_not_strip_whitespace
    # Normalization is Domain::TagName's job and happens before construction
    refute Domain::Tag.new(name: 'Gaming').same_name?(' Gaming ')
  end

  # === with_id ===

  def test_with_id_returns_a_copy_carrying_the_id
    assert_equal 9, Domain::Tag.new(name: 'Gaming').with_id(9).id
  end

  def test_with_id_does_not_mutate_the_original
    tag = Domain::Tag.new(name: 'Gaming')
    tag.with_id(9)

    assert_nil tag.id
  end

  # === Value semantics ===

  def test_tags_with_the_same_attributes_are_equal
    assert_equal Domain::Tag.new(id: 1, name: 'Gaming'), Domain::Tag.new(id: 1, name: 'Gaming')
  end

  def test_tags_differing_in_id_are_not_equal
    refute_equal Domain::Tag.new(id: 1, name: 'Gaming'), Domain::Tag.new(id: 2, name: 'Gaming')
  end

  def test_equality_is_case_sensitive
    refute_equal Domain::Tag.new(name: 'Gaming'), Domain::Tag.new(name: 'gaming')
  end

  def test_is_not_equal_to_a_lookalike_hash
    refute_equal Domain::Tag.new(id: 1, name: 'Gaming'), { id: 1, name: 'Gaming' }
  end

  def test_can_be_used_as_a_hash_key
    seen = {}
    seen[Domain::Tag.new(id: 1, name: 'Gaming')] = :yes

    assert_equal :yes, seen[Domain::Tag.new(id: 1, name: 'Gaming')]
  end
end
