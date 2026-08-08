require 'minitest/autorun'
require_relative '../../lib/domain/url_classifier'

class UrlClassifierTest < Minitest::Test
  # ========================================
  # classify
  # ========================================

  def test_https_url_is_an_absolute_url
    assert_equal :absolute_url, Domain::UrlClassifier.classify("https://example.com")
  end

  def test_http_url_is_an_absolute_url
    assert_equal :absolute_url, Domain::UrlClassifier.classify("http://example.com")
  end

  def test_file_url_is_an_absolute_url
    assert_equal :absolute_url, Domain::UrlClassifier.classify("file:///tmp/notes.md")
  end

  def test_absolute_filesystem_path_is_an_absolute_path
    assert_equal :absolute_path, Domain::UrlClassifier.classify("/tmp/notes.md")
  end

  def test_home_relative_path_is_a_home_path
    assert_equal :home_path, Domain::UrlClassifier.classify("~/notes.md")
  end

  def test_bare_tilde_without_a_slash_is_a_search
    assert_equal :search, Domain::UrlClassifier.classify("~notes")
  end

  def test_bare_domain_is_a_domain
    assert_equal :domain, Domain::UrlClassifier.classify("example.com")
  end

  def test_domain_with_a_path_is_a_domain
    assert_equal :domain, Domain::UrlClassifier.classify("github.com/anthropics")
  end

  def test_hyphenated_domain_is_a_domain
    assert_equal :domain, Domain::UrlClassifier.classify("my-site.co.uk")
  end

  def test_domain_with_a_space_is_a_search
    assert_equal :search, Domain::UrlClassifier.classify("example.com and friends")
  end

  def test_multi_word_text_is_a_search
    assert_equal :search, Domain::UrlClassifier.classify("what is hindley milner")
  end

  def test_single_word_without_a_dot_is_a_search
    assert_equal :search, Domain::UrlClassifier.classify("ruby")
  end

  def test_empty_text_is_a_search
    assert_equal :search, Domain::UrlClassifier.classify("")
  end

  def test_absolute_url_wins_over_the_domain_pattern
    assert_equal :absolute_url, Domain::UrlClassifier.classify("https://example.com/a b")
  end

  # ========================================
  # search_url
  # ========================================

  def test_search_url_escapes_the_query
    assert_equal "https://www.google.com/search?q=hello+world",
                 Domain::UrlClassifier.search_url("hello world")
  end

  def test_search_url_escapes_special_characters
    assert_equal "https://www.google.com/search?q=c%2B%2B+traits",
                 Domain::UrlClassifier.search_url("c++ traits")
  end

  def test_search_url_handles_an_empty_query
    assert_equal "https://www.google.com/search?q=", Domain::UrlClassifier.search_url("")
  end

  # ========================================
  # explicit_address?
  # ========================================

  def test_text_with_a_scheme_separator_is_an_explicit_address
    assert Domain::UrlClassifier.explicit_address?("https://example.com")
  end

  def test_localhost_is_an_explicit_address
    assert Domain::UrlClassifier.explicit_address?("localhost:3000")
  end

  def test_loopback_ip_is_an_explicit_address
    assert Domain::UrlClassifier.explicit_address?("127.0.0.1:8080")
  end

  def test_private_class_c_ip_is_an_explicit_address
    assert Domain::UrlClassifier.explicit_address?("192.168.1.10")
  end

  def test_private_class_a_ip_is_an_explicit_address
    assert Domain::UrlClassifier.explicit_address?("10.0.0.5")
  end

  def test_bare_domain_is_not_an_explicit_address
    assert_equal false, Domain::UrlClassifier.explicit_address?("example.com")
  end

  def test_search_text_is_not_an_explicit_address
    assert_equal false, Domain::UrlClassifier.explicit_address?("what is ruby")
  end

  def test_prefix_must_appear_at_the_start
    assert_equal false, Domain::UrlClassifier.explicit_address?("my localhost notes")
  end

  def test_nil_is_not_an_explicit_address
    assert_equal false, Domain::UrlClassifier.explicit_address?(nil)
  end
end
