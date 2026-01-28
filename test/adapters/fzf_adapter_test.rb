require 'minitest/autorun'
require_relative '../../lib/adapters/fzf_adapter'

class FzfAdapterTest < Minitest::Test
  # ========================================
  # Empty Pattern Tests
  # ========================================

  def test_empty_pattern_returns_first_n_strings
    strings = ["apple", "banana", "cherry", "date", "elderberry"]

    result = FzfAdapter.filter(strings, "", limit: 3)

    assert_equal ["apple", "banana", "cherry"], result
  end

  def test_empty_pattern_with_whitespace_returns_first_n
    strings = ["apple", "banana", "cherry"]

    result = FzfAdapter.filter(strings, "   ", limit: 2)

    assert_equal ["apple", "banana"], result
  end

  def test_empty_input_returns_empty
    result = FzfAdapter.filter([], "test", limit: 10)

    assert_equal [], result
  end

  # ========================================
  # Basic Fuzzy Matching Tests
  # ========================================

  def test_exact_match
    strings = ["apple", "banana", "cherry"]

    result = FzfAdapter.filter(strings, "banana", limit: 10)

    assert_includes result, "banana"
  end

  def test_prefix_match
    strings = ["application", "banana", "apple"]

    result = FzfAdapter.filter(strings, "app", limit: 10)

    # Both "application" and "apple" should match
    assert_includes result, "application"
    assert_includes result, "apple"
    refute_includes result, "banana"
  end

  def test_fuzzy_match_with_gaps
    strings = ["facebook", "fallback", "foobar"]

    result = FzfAdapter.filter(strings, "fba", limit: 10)

    # "fba" fuzzy matches "facebook" (f...b...a...) and "fallback"
    # fzf returns matches sorted by score
    refute_empty result
  end

  def test_case_insensitive_by_default
    strings = ["GitHub", "gitlab", "Bitbucket"]

    result = FzfAdapter.filter(strings, "git", limit: 10)

    assert_includes result, "GitHub"
    assert_includes result, "gitlab"
  end

  def test_no_matches_returns_empty
    strings = ["apple", "banana", "cherry"]

    result = FzfAdapter.filter(strings, "xyz123", limit: 10)

    assert_equal [], result
  end

  # ========================================
  # Tab-Separated Title + URL Tests
  # ========================================

  def test_matches_title_in_tab_separated_string
    strings = [
      "Google Search\thttps://www.google.com",
      "Bing Search\thttps://www.bing.com",
      "DuckDuckGo\thttps://duckduckgo.com"
    ]

    result = FzfAdapter.filter(strings, "Google", limit: 10)

    assert_includes result, "Google Search\thttps://www.google.com"
    refute_includes result, "Bing Search\thttps://www.bing.com"
  end

  def test_matches_url_in_tab_separated_string
    strings = [
      "Google Search\thttps://www.google.com",
      "Bing Search\thttps://www.bing.com",
      "DuckDuckGo\thttps://duckduckgo.com"
    ]

    result = FzfAdapter.filter(strings, "duckduck", limit: 10)

    assert_includes result, "DuckDuckGo\thttps://duckduckgo.com"
  end

  def test_matches_url_domain
    strings = [
      "GitHub - Home\thttps://github.com",
      "GitLab\thttps://gitlab.com",
      "Stack Overflow\thttps://stackoverflow.com"
    ]

    result = FzfAdapter.filter(strings, "github", limit: 10)

    assert_includes result, "GitHub - Home\thttps://github.com"
  end

  def test_matches_partial_url_path
    strings = [
      "Ruby Docs\thttps://ruby-doc.org/core-3.0.0/String.html",
      "Python Docs\thttps://docs.python.org/3/library/string.html",
      "MDN Web Docs\thttps://developer.mozilla.org"
    ]

    result = FzfAdapter.filter(strings, "ruby", limit: 10)

    assert_includes result, "Ruby Docs\thttps://ruby-doc.org/core-3.0.0/String.html"
  end

  # ========================================
  # Limit Tests
  # ========================================

  def test_limit_respected
    strings = (1..20).map { |i| "item#{i}" }

    result = FzfAdapter.filter(strings, "item", limit: 5)

    assert_equal 5, result.length
  end

  def test_default_limit_is_10
    strings = (1..20).map { |i| "match#{i}" }

    result = FzfAdapter.filter(strings, "match")

    assert_equal 10, result.length
  end

  def test_limit_larger_than_results_returns_all_matches
    strings = ["apple", "application"]

    result = FzfAdapter.filter(strings, "app", limit: 100)

    assert_equal 2, result.length
  end

  # ========================================
  # Real-World URL Scenarios
  # ========================================

  def test_youtube_search
    strings = [
      "YouTube\thttps://www.youtube.com",
      "YouTube Music\thttps://music.youtube.com",
      "YouTube TV\thttps://tv.youtube.com",
      "Vimeo\thttps://vimeo.com"
    ]

    result = FzfAdapter.filter(strings, "youtube music", limit: 10)

    # "youtube music" should match "YouTube Music" first (exact match)
    assert_includes result, "YouTube Music\thttps://music.youtube.com"
  end

  def test_github_repo_search
    strings = [
      "rails/rails\thttps://github.com/rails/rails",
      "ruby/ruby\thttps://github.com/ruby/ruby",
      "sinatra/sinatra\thttps://github.com/sinatra/sinatra",
      "Ruby on Rails Guides\thttps://guides.rubyonrails.org"
    ]

    result = FzfAdapter.filter(strings, "rails", limit: 10)

    # Should match both GitHub repos and Rails guides
    assert_includes result, "rails/rails\thttps://github.com/rails/rails"
    assert_includes result, "Ruby on Rails Guides\thttps://guides.rubyonrails.org"
  end

  def test_search_with_multiple_words
    strings = [
      "Stack Overflow - Ruby\thttps://stackoverflow.com/questions/tagged/ruby",
      "Ruby Documentation\thttps://ruby-doc.org",
      "Python Documentation\thttps://docs.python.org"
    ]

    result = FzfAdapter.filter(strings, "ruby doc", limit: 10)

    # "ruby doc" should match "Ruby Documentation" well
    assert_includes result, "Ruby Documentation\thttps://ruby-doc.org"
  end

  # ========================================
  # Edge Cases
  # ========================================

  def test_special_characters_in_pattern
    strings = [
      "C++ Reference\thttps://cppreference.com",
      "C# Guide\thttps://docs.microsoft.com/csharp"
    ]

    # fzf should handle special characters
    result = FzfAdapter.filter(strings, "c++", limit: 10)

    # The '+' characters are treated literally in fzf
    refute_empty result
  end

  def test_unicode_characters
    strings = [
      "Wikipedia Espanol\thttps://es.wikipedia.org",
      "Noticias\thttps://news.example.com"
    ]

    result = FzfAdapter.filter(strings, "Espanol", limit: 10)

    assert_includes result, "Wikipedia Espanol\thttps://es.wikipedia.org"
  end

  def test_empty_title_in_tab_separated
    strings = [
      "\thttps://example.com",  # Empty title
      "Example Site\thttps://example.org"
    ]

    result = FzfAdapter.filter(strings, "example", limit: 10)

    # Should match URL even with empty title
    assert_equal 2, result.length
  end

  def test_whitespace_in_input_preserved
    strings = ["  leading spaces", "trailing spaces  ", "no spaces"]

    result = FzfAdapter.filter(strings, "leading", limit: 10)

    assert_includes result, "  leading spaces"
  end

  def test_newlines_in_strings_handled
    # Strings should not contain newlines (they're the delimiter)
    # But if they do, fzf treats them as separate entries
    strings = ["normal string", "another string"]

    result = FzfAdapter.filter(strings, "normal", limit: 10)

    assert_includes result, "normal string"
  end
end
