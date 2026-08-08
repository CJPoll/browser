require 'minitest/autorun'
require_relative '../../lib/domain/visit'

class DomainVisitTest < Minitest::Test
  VISITED_AT = Time.at(1_700_003_600).freeze

  def build_page(**overrides)
    Domain::Page.new(**{ uri: 'https://example.com/article' }.merge(overrides))
  end

  def build_visit(**overrides)
    Domain::Visit.new(**{ visited_at: VISITED_AT }.merge(overrides))
  end

  # === Construction ===

  def test_visited_at_is_required
    error = assert_raises(ArgumentError) { Domain::Visit.new(visited_at: nil) }

    assert_match(/visited_at/, error.message)
  end

  def test_visited_at_alone_is_enough
    visit = build_visit

    assert_equal VISITED_AT, visit.visited_at
    assert_nil visit.id
    assert_nil visit.page_id
    assert_nil visit.title
    assert_nil visit.page
  end

  def test_every_attribute_is_readable
    page = build_page(id: 3)
    visit = build_visit(id: 9, page_id: 3, title: 'An Article', page: page)

    assert_equal 9, visit.id
    assert_equal 3, visit.page_id
    assert_equal 'An Article', visit.title
    assert_equal page, visit.page
  end

  def test_a_visit_is_frozen
    assert_predicate build_visit, :frozen?
  end

  # === Delegation to the page ===

  def test_uri_comes_from_the_page
    assert_equal 'https://example.com/article', build_visit(page: build_page).uri
  end

  def test_uri_is_nil_without_a_page
    assert_nil build_visit.uri
  end

  def test_favicon_comes_from_the_page
    assert_equal 'PNGDATA', build_visit(page: build_page(favicon: 'PNGDATA')).favicon
  end

  def test_favicon_is_nil_without_a_page
    assert_nil build_visit.favicon
  end

  # === display_title ===
  #
  # The title recorded with the visit wins: a single-page app changes its title
  # without changing the page row, and the visit is what the user saw.

  def test_display_title_prefers_the_visit_title
    visit = build_visit(title: 'As seen', page: build_page(title: 'Page title'))

    assert_equal 'As seen', visit.display_title
  end

  def test_display_title_falls_back_to_the_page_title
    visit = build_visit(title: nil, page: build_page(title: 'Page title'))

    assert_equal 'Page title', visit.display_title
  end

  def test_display_title_falls_back_to_the_uri
    visit = build_visit(title: nil, page: build_page(title: nil))

    assert_equal 'https://example.com/article', visit.display_title
  end

  def test_display_title_is_nil_when_there_is_nothing_to_show
    assert_nil build_visit.display_title
  end

  # === with ===

  def test_with_returns_a_copy_carrying_the_override
    visit = build_visit(title: 'Before')

    updated = visit.with(title: 'After')

    assert_equal 'After', updated.title
    assert_equal 'Before', visit.title, 'the original must not change'
  end

  def test_with_keeps_every_other_attribute
    visit = build_visit(id: 9, page_id: 3, title: 'An Article', page: build_page(id: 3))

    updated = visit.with(title: 'Renamed')

    assert_equal visit.to_h.merge(title: 'Renamed'), updated.to_h
  end

  # === Equality ===

  def test_visits_with_the_same_attributes_are_equal
    assert_equal build_visit(id: 1, page: build_page), build_visit(id: 1, page: build_page)
  end

  def test_visits_differing_in_their_page_are_not_equal
    refute_equal build_visit(page: build_page(title: 'A')),
                 build_visit(page: build_page(title: 'B'))
  end

  def test_a_visit_is_not_equal_to_a_lookalike_hash
    visit = build_visit(id: 1)

    refute_equal visit, visit.to_h
  end

  def test_equal_visits_hash_alike
    assert_equal 1, [build_visit(id: 1), build_visit(id: 1)].uniq.size
  end

  # === to_h ===

  def test_to_h_lists_every_attribute
    expected = %i[id page_id visited_at title page]

    assert_equal expected.sort, build_visit.to_h.keys.sort
  end
end
