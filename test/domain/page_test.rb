require 'minitest/autorun'
require_relative '../../lib/domain/page'

class DomainPageTest < Minitest::Test
  CREATED_AT = Time.at(1_700_000_000).freeze
  LAST_VISITED_AT = Time.at(1_700_003_600).freeze

  def build_page(**overrides)
    Domain::Page.new(**{ uri: 'https://example.com/article' }.merge(overrides))
  end

  # === Construction ===

  def test_uri_is_required
    error = assert_raises(ArgumentError) { Domain::Page.new(uri: nil) }

    assert_match(/uri/, error.message)
  end

  def test_empty_uri_is_rejected
    assert_raises(ArgumentError) { Domain::Page.new(uri: '') }
  end

  def test_uri_alone_is_enough
    page = build_page

    assert_equal 'https://example.com/article', page.uri
    assert_nil page.id
    assert_nil page.site_id
    assert_nil page.title
    assert_nil page.favicon
    assert_nil page.created_at
    assert_nil page.last_visited_at
  end

  def test_visit_count_defaults_to_zero
    assert_equal 0, build_page.visit_count
  end

  def test_every_attribute_is_readable
    page = build_page(
      id: 7,
      site_id: 3,
      title: 'An Article',
      favicon: 'PNGDATA',
      created_at: CREATED_AT,
      last_visited_at: LAST_VISITED_AT,
      visit_count: 12
    )

    assert_equal 7, page.id
    assert_equal 3, page.site_id
    assert_equal 'An Article', page.title
    assert_equal 'PNGDATA', page.favicon
    assert_equal CREATED_AT, page.created_at
    assert_equal LAST_VISITED_AT, page.last_visited_at
    assert_equal 12, page.visit_count
  end

  def test_a_page_is_frozen
    assert_predicate build_page, :frozen?
  end

  # === display_title ===

  def test_display_title_prefers_the_title
    assert_equal 'An Article', build_page(title: 'An Article').display_title
  end

  def test_display_title_falls_back_to_the_uri
    assert_equal 'https://example.com/article', build_page(title: nil).display_title
  end

  # === with ===

  def test_with_returns_a_copy_carrying_the_override
    page = build_page(visit_count: 2)

    updated = page.with(visit_count: 3)

    assert_equal 3, updated.visit_count
    assert_equal 2, page.visit_count, 'the original must not change'
    assert_equal page.uri, updated.uri
  end

  def test_with_keeps_every_other_attribute
    page = build_page(id: 7, title: 'An Article', favicon: 'PNGDATA',
                      created_at: CREATED_AT, last_visited_at: LAST_VISITED_AT)

    updated = page.with(title: 'Renamed')

    assert_equal page.to_h.merge(title: 'Renamed'), updated.to_h
  end

  # === Equality ===

  def test_pages_with_the_same_attributes_are_equal
    assert_equal build_page(id: 1), build_page(id: 1)
  end

  def test_pages_differing_in_any_attribute_are_not_equal
    refute_equal build_page(id: 1), build_page(id: 2)
    refute_equal build_page(title: 'A'), build_page(title: 'B')
  end

  def test_a_page_is_not_equal_to_a_lookalike_hash
    page = build_page(id: 1)

    refute_equal page, page.to_h
  end

  def test_equal_pages_hash_alike
    assert_equal build_page(id: 1).hash, build_page(id: 1).hash
    assert_equal 1, [build_page(id: 1), build_page(id: 1)].uniq.size
  end

  # === to_h ===

  def test_to_h_lists_every_attribute
    expected = %i[id site_id uri title favicon created_at last_visited_at visit_count]

    assert_equal expected.sort, build_page.to_h.keys.sort
  end
end
