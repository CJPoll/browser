require 'minitest/autorun'
require_relative '../../lib/domain/sidebar_title'

class SidebarTitleTest < Minitest::Test
  # ========================================
  # size and weight
  # ========================================

  def test_markup_carries_the_x_large_size
    assert_includes Domain::SidebarTitle.markup("Hello"), "size='large'"
  end

  def test_markup_is_bold
    assert_includes Domain::SidebarTitle.markup("Hello"), "weight='bold'"
  end

  def test_title_size_constant_is_x_large
    assert_equal 'large', Domain::SidebarTitle::TITLE_SIZE
  end

  def test_markup_wraps_the_escaped_text_in_a_single_span
    assert_equal "<span size='large' weight='bold'>Hello</span>",
                 Domain::SidebarTitle.markup("Hello")
  end

  # ========================================
  # escaping
  # ========================================

  def test_markup_escapes_ampersands_and_angle_brackets
    result = Domain::SidebarTitle.markup("A & B <x>")
    assert_includes result, "A &amp; B &lt;x&gt;"
    refute_includes result, "A & B <x>"
  end

  def test_markup_escapes_quotes_the_way_cgi_does
    # Pin CGI.escapeHTML behaviour: it escapes both single and double quotes.
    result = Domain::SidebarTitle.markup(%q{"a" 'b'})
    assert_includes result, CGI.escapeHTML(%q{"a" 'b'})
  end

  def test_markup_matches_cgi_escapehtml_for_the_content
    title = "Tom & Jerry <fun> \"quoted\""
    expected = "<span size='large' weight='bold'>#{CGI.escapeHTML(title)}</span>"
    assert_equal expected, Domain::SidebarTitle.markup(title)
  end

  # ========================================
  # truncation
  # ========================================

  def test_default_max_length_keeps_sixty_one_characters
    long = "a" * 100
    result = Domain::SidebarTitle.markup(long)
    assert_includes result, "a" * 61
    refute_includes result, "a" * 62
  end

  def test_explicit_max_length_of_forty_one_keeps_forty_one_characters
    long = "a" * 100
    result = Domain::SidebarTitle.markup(long, max_length: 41)
    assert_includes result, "a" * 41
    refute_includes result, "a" * 42
  end

  def test_short_titles_are_not_padded_or_truncated
    assert_equal "<span size='large' weight='bold'>abc</span>",
                 Domain::SidebarTitle.markup("abc")
  end

  def test_a_title_exactly_at_the_limit_is_kept_whole
    exact = "a" * 61
    result = Domain::SidebarTitle.markup(exact)
    assert_includes result, "a" * 61
    refute_includes result, "a" * 62
  end

  # ========================================
  # safe handling of nil and empty
  # ========================================

  def test_nil_title_produces_valid_empty_markup_without_raising
    assert_equal "<span size='large' weight='bold'></span>",
                 Domain::SidebarTitle.markup(nil)
  end

  def test_empty_title_produces_valid_empty_markup_without_raising
    assert_equal "<span size='large' weight='bold'></span>",
                 Domain::SidebarTitle.markup("")
  end
end
