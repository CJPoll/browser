require_relative '../test_helper'
require_relative '../../lib/domain/pdf_outline'

# Tests for Domain::PdfOutline - markdown headings to a PDF bookmark tree
class PdfOutlineTest < Minitest::Test
  # ============================================================
  # headings
  # ============================================================

  def test_extracts_a_single_heading
    headings = Domain::PdfOutline.headings("# Title\n")

    assert_equal 1, headings.size
    assert_equal 'Title', headings.first.text
    assert_equal 1, headings.first.level
    assert_nil headings.first.page
  end

  def test_extracts_every_heading_level_from_one_to_six
    markdown = (1..6).map { |level| "#{'#' * level} Level #{level}\n" }.join

    headings = Domain::PdfOutline.headings(markdown)

    assert_equal [1, 2, 3, 4, 5, 6], headings.map(&:level)
    assert_equal (1..6).map { |l| "Level #{l}" }, headings.map(&:text)
  end

  def test_ignores_body_text
    headings = Domain::PdfOutline.headings("Intro paragraph\n\n## Section\n\nMore text\n")

    assert_equal ['Section'], headings.map(&:text)
  end

  def test_strips_surrounding_whitespace_from_the_text
    headings = Domain::PdfOutline.headings("#   Spaced Out   \n")

    assert_equal 'Spaced Out', headings.first.text
  end

  def test_ignores_a_hash_with_no_text
    assert_empty Domain::PdfOutline.headings("#\n# \n")
  end

  def test_ignores_a_hash_that_is_not_followed_by_a_space
    assert_empty Domain::PdfOutline.headings("#NotAHeading\n")
  end

  def test_ignores_seven_or_more_hashes
    assert_empty Domain::PdfOutline.headings("####### Too deep\n")
  end

  def test_returns_an_empty_list_for_content_without_headings
    assert_empty Domain::PdfOutline.headings("just words\n")
  end

  def test_returns_an_empty_list_for_nil_content
    assert_empty Domain::PdfOutline.headings(nil)
  end

  # Known wart, preserved from the original processor: the pattern is applied
  # line by line with no awareness of fenced code blocks, so a comment inside
  # a code sample becomes a bookmark.
  def test_wart_a_hash_comment_inside_a_code_fence_is_read_as_a_heading
    markdown = "```ruby\n# not really a heading\n```\n"

    assert_equal ['not really a heading'], Domain::PdfOutline.headings(markdown).map(&:text)
  end

  # ============================================================
  # plan
  # ============================================================

  def test_plans_a_flat_list_as_top_level_bookmarks
    plan = Domain::PdfOutline.plan([located('One', 1, 0), located('Two', 1, 3)])

    assert_equal ['One', 'Two'], plan.map(&:text)
    assert_equal [0, 3], plan.map(&:page)
    assert_equal [nil, nil], plan.map(&:parent_index)
  end

  def test_nests_a_deeper_heading_under_the_one_before_it
    plan = Domain::PdfOutline.plan([located('Chapter', 1, 0), located('Section', 2, 1)])

    assert_nil plan[0].parent_index
    assert_equal 0, plan[1].parent_index
  end

  def test_nests_three_levels_deep
    plan = Domain::PdfOutline.plan([
      located('Chapter', 1, 0),
      located('Section', 2, 1),
      located('Subsection', 3, 2)
    ])

    assert_equal [nil, 0, 1], plan.map(&:parent_index)
  end

  def test_returns_to_the_previous_level_after_a_deeper_run
    plan = Domain::PdfOutline.plan([
      located('Chapter', 1, 0),
      located('Section', 2, 1),
      located('Next Chapter', 1, 2),
      located('Its Section', 2, 3)
    ])

    assert_equal [nil, 0, nil, 2], plan.map(&:parent_index)
  end

  def test_a_deeper_first_heading_is_still_top_level
    plan = Domain::PdfOutline.plan([located('Section', 3, 0)])

    assert_nil plan.first.parent_index
  end

  def test_a_shallower_heading_after_a_deeper_one_starts_a_new_branch
    plan = Domain::PdfOutline.plan([
      located('Chapter', 1, 0),
      located('Subsection', 3, 1),
      located('Section', 2, 2)
    ])

    assert_equal [nil, 0, 0], plan.map(&:parent_index)
  end

  def test_carries_the_page_of_each_heading
    plan = Domain::PdfOutline.plan([located('Chapter', 1, 4), located('Section', 2, 7)])

    assert_equal [4, 7], plan.map(&:page)
  end

  def test_plans_nothing_for_no_headings
    assert_empty Domain::PdfOutline.plan([])
  end

  # Known wart, preserved from the original processor: when a document skips a
  # level and then repeats the deeper one (h1, h3, h3), the parent slot the
  # second h3 would attach to has been vacated, and the outline cannot be
  # built. The original raised NoMethodError on nil here and the caller
  # reported "failed to add bookmarks"; this raises by name so the same
  # rescue reports the same thing.
  def test_wart_a_repeated_heading_below_a_skipped_level_cannot_be_planned
    assert_raises(Domain::PdfOutline::MalformedHeadingLevels) do
      Domain::PdfOutline.plan([
        located('Chapter', 1, 0),
        located('Skipped To', 3, 1),
        located('Again', 3, 2)
      ])
    end
  end

  private

  def located(text, level, page)
    Domain::PdfOutline::Heading.new(text: text, level: level, page: page)
  end
end
