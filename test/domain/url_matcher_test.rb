require 'minitest/autorun'
require_relative '../../lib/domain/url_matcher'

class UrlMatcherTest < Minitest::Test
  # ========================================
  # Base URL comparison
  # ========================================

  def test_identical_urls_match
    assert Domain::UrlMatcher.match?("https://example.com/page", "https://example.com/page")
  end

  def test_different_hosts_do_not_match
    refute Domain::UrlMatcher.match?("https://example.com/page", "https://other.com/page")
  end

  def test_different_paths_do_not_match
    refute Domain::UrlMatcher.match?("https://example.com/one", "https://example.com/two")
  end

  def test_different_schemes_do_not_match
    refute Domain::UrlMatcher.match?("http://example.com/page", "https://example.com/page")
  end

  def test_trailing_slash_on_one_side_is_ignored
    assert Domain::UrlMatcher.match?("https://example.com/page/", "https://example.com/page")
  end

  def test_trailing_slash_on_both_sides_is_ignored
    assert Domain::UrlMatcher.match?("https://example.com/page/", "https://example.com/page/")
  end

  def test_bare_host_matches_bare_host_with_slash
    assert Domain::UrlMatcher.match?("https://example.com", "https://example.com/")
  end

  def test_fragments_are_ignored
    assert Domain::UrlMatcher.match?("https://example.com/page#section", "https://example.com/page")
  end

  def test_paths_are_case_sensitive
    refute Domain::UrlMatcher.match?("https://example.com/Page", "https://example.com/page")
  end

  # Known wart, preserved from the original implementation: the base comparison
  # is built from scheme/host/path only, so the port is not part of the match.
  def test_port_is_not_part_of_the_comparison
    assert Domain::UrlMatcher.match?("https://example.com:8443/page", "https://example.com/page")
  end

  # ========================================
  # Query parameter subset matching
  # ========================================

  def test_identical_query_parameters_match
    assert Domain::UrlMatcher.match?(
      "https://youtube.com/watch?v=abc",
      "https://youtube.com/watch?v=abc"
    )
  end

  def test_first_url_may_carry_extra_parameters
    assert Domain::UrlMatcher.match?(
      "https://youtube.com/watch?v=abc&pp=tracking",
      "https://youtube.com/watch?v=abc"
    )
  end

  def test_second_url_may_carry_extra_parameters
    assert Domain::UrlMatcher.match?(
      "https://youtube.com/watch?v=abc",
      "https://youtube.com/watch?v=abc&t=10s"
    )
  end

  def test_conflicting_parameter_values_do_not_match
    refute Domain::UrlMatcher.match?(
      "https://youtube.com/watch?v=abc",
      "https://youtube.com/watch?v=xyz"
    )
  end

  def test_disjoint_parameters_do_not_match
    refute Domain::UrlMatcher.match?(
      "https://example.com/search?q=ruby",
      "https://example.com/search?page=2"
    )
  end

  def test_query_parameters_on_one_side_only_are_a_subset_match
    assert Domain::UrlMatcher.match?(
      "https://example.com/search",
      "https://example.com/search?q=ruby"
    )
  end

  def test_repeated_parameters_must_agree_in_full
    assert Domain::UrlMatcher.match?(
      "https://example.com/x?a=1&a=2",
      "https://example.com/x?a=1&a=2"
    )
  end

  def test_repeated_parameters_with_a_missing_value_do_not_match
    refute Domain::UrlMatcher.match?(
      "https://example.com/x?a=1&a=2",
      "https://example.com/x?a=1"
    )
  end

  # ========================================
  # Invalid input
  # ========================================

  def test_nil_first_url_does_not_match
    refute Domain::UrlMatcher.match?(nil, "https://example.com")
  end

  def test_nil_second_url_does_not_match
    refute Domain::UrlMatcher.match?("https://example.com", nil)
  end

  def test_unparseable_url_does_not_match
    refute Domain::UrlMatcher.match?("http://exa mple.com", "https://example.com")
  end

  def test_two_unparseable_urls_do_not_match
    refute Domain::UrlMatcher.match?("ht tp://a", "ht tp://a")
  end

  # ========================================
  # params_subset?
  # ========================================

  def test_empty_subset_is_a_subset_of_anything
    assert Domain::UrlMatcher.params_subset?({}, { "a" => ["1"] })
  end

  def test_equal_parameter_hashes_are_subsets
    assert Domain::UrlMatcher.params_subset?({ "a" => ["1"] }, { "a" => ["1"] })
  end

  def test_missing_key_is_not_a_subset
    refute Domain::UrlMatcher.params_subset?({ "a" => ["1"] }, { "b" => ["1"] })
  end

  def test_differing_value_is_not_a_subset
    refute Domain::UrlMatcher.params_subset?({ "a" => ["1"] }, { "a" => ["2"] })
  end

  def test_superset_with_extra_keys_still_contains_the_subset
    assert Domain::UrlMatcher.params_subset?({ "a" => ["1"] }, { "a" => ["1"], "b" => ["2"] })
  end
end
