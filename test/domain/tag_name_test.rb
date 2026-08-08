require 'minitest/autorun'
require_relative '../../lib/domain/tag_name'

class TagNameTest < Minitest::Test
  # ========================================
  # normalize
  # ========================================

  def test_normalize_returns_nil_for_nil
    assert_nil Domain::TagName.normalize(nil)
  end

  def test_normalize_returns_nil_for_an_empty_string
    assert_nil Domain::TagName.normalize("")
  end

  def test_normalize_returns_nil_for_whitespace_only
    assert_nil Domain::TagName.normalize("   \t\n ")
  end

  def test_normalize_strips_surrounding_whitespace
    assert_equal "Gaming", Domain::TagName.normalize("  Gaming  ")
  end

  def test_normalize_collapses_internal_whitespace
    assert_equal "read later", Domain::TagName.normalize("read     later")
  end

  def test_normalize_collapses_tabs_and_newlines
    assert_equal "read later", Domain::TagName.normalize("read\t\nlater")
  end

  def test_normalize_preserves_case
    assert_equal "YouTube", Domain::TagName.normalize("YouTube")
  end

  def test_normalize_leaves_an_already_normal_name_untouched
    assert_equal "youtube", Domain::TagName.normalize("youtube")
  end

  def test_normalize_does_not_truncate_long_names
    long_name = "a" * 150
    assert_equal long_name, Domain::TagName.normalize(long_name)
  end

  def test_normalize_is_idempotent
    once = Domain::TagName.normalize("  read   later  ")
    assert_equal once, Domain::TagName.normalize(once)
  end

  # ========================================
  # valid?
  # ========================================

  def test_nil_is_not_valid
    refute Domain::TagName.valid?(nil)
  end

  def test_empty_string_is_not_valid
    refute Domain::TagName.valid?("")
  end

  def test_whitespace_only_is_not_valid
    refute Domain::TagName.valid?("   ")
  end

  def test_ordinary_name_is_valid
    assert Domain::TagName.valid?("YouTube")
  end

  def test_name_at_the_length_limit_is_valid
    assert Domain::TagName.valid?("a" * Domain::TagName::MAX_LENGTH)
  end

  def test_name_one_over_the_length_limit_is_not_valid
    refute Domain::TagName.valid?("a" * (Domain::TagName::MAX_LENGTH + 1))
  end

  def test_length_is_measured_after_normalization
    padded = "  #{'a' * Domain::TagName::MAX_LENGTH}  "
    assert Domain::TagName.valid?(padded)
  end

  def test_collapsed_whitespace_can_bring_a_name_under_the_limit
    # 99 "a"s + ten spaces + "b" = 110 raw characters; collapsing the run of
    # spaces to one leaves 101, which is still over the limit.
    raw = "#{'a' * 99}#{' ' * 10}b"
    assert_operator raw.length, :>, Domain::TagName::MAX_LENGTH
    assert_equal 101, Domain::TagName.normalize(raw).length
    refute Domain::TagName.valid?(raw)
  end

  def test_collapsed_whitespace_is_measured_not_the_raw_length
    raw = "#{'a' * 98}#{' ' * 10}b"
    assert_operator raw.length, :>, Domain::TagName::MAX_LENGTH
    assert_equal 100, Domain::TagName.normalize(raw).length
    assert Domain::TagName.valid?(raw)
  end

  def test_max_length_is_one_hundred
    assert_equal 100, Domain::TagName::MAX_LENGTH
  end
end
