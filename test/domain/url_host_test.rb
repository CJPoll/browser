require 'minitest/autorun'
require 'uri'
require_relative '../../lib/domain/url_host'

class UrlHostTest < Minitest::Test
  # ========================================
  # host
  # ========================================

  def test_extracts_host_from_an_absolute_url
    assert_equal "example.com", Domain::UrlHost.host("https://example.com/path?q=1")
  end

  def test_extracts_host_from_a_url_with_a_port
    assert_equal "example.com", Domain::UrlHost.host("https://example.com:8443/path")
  end

  def test_extracts_host_from_a_url_with_userinfo
    assert_equal "example.com", Domain::UrlHost.host("https://user:secret@example.com/path")
  end

  def test_preserves_host_case
    assert_equal "Example.COM", Domain::UrlHost.host("https://Example.COM/path")
  end

  def test_returns_nil_for_nil
    assert_nil Domain::UrlHost.host(nil)
  end

  def test_returns_nil_for_an_unparseable_url
    assert_nil Domain::UrlHost.host("http://exa mple.com")
  end

  def test_returns_nil_for_a_relative_path
    assert_nil Domain::UrlHost.host("relative/path")
  end

  def test_returns_nil_for_a_bare_hostname
    assert_nil Domain::UrlHost.host("example.com")
  end

  # ========================================
  # host_or_bare_name
  # ========================================

  def test_bare_hostname_is_returned_as_is
    assert_equal "claude.ai", Domain::UrlHost.host_or_bare_name("claude.ai")
  end

  def test_absolute_url_still_yields_its_host
    assert_equal "claude.ai", Domain::UrlHost.host_or_bare_name("https://claude.ai/chat")
  end

  def test_string_containing_a_slash_is_not_treated_as_a_bare_hostname
    assert_nil Domain::UrlHost.host_or_bare_name("claude.ai/chat")
  end

  def test_host_or_bare_name_returns_nil_for_nil
    assert_nil Domain::UrlHost.host_or_bare_name(nil)
  end

  def test_host_or_bare_name_returns_nil_for_an_unparseable_url
    assert_nil Domain::UrlHost.host_or_bare_name("http://exa mple.com")
  end

  # ========================================
  # authority
  # ========================================

  def test_http_authority_is_the_host_alone
    assert_equal "example.com", Domain::UrlHost.authority(URI.parse("http://example.com/page"))
  end

  def test_https_authority_is_the_host_alone
    assert_equal "example.com", Domain::UrlHost.authority(URI.parse("https://example.com/page"))
  end

  def test_http_authority_ignores_an_explicit_port
    assert_equal "example.com", Domain::UrlHost.authority(URI.parse("http://example.com:8080/page"))
  end

  def test_non_http_authority_includes_the_port
    assert_equal "example.com:21", Domain::UrlHost.authority(URI.parse("ftp://example.com/pub"))
  end

  def test_authority_is_nil_when_the_uri_has_no_host
    assert_nil Domain::UrlHost.authority(URI.parse("about:blank"))
  end

  def test_authority_of_a_local_file_uri_is_the_empty_host
    assert_equal "", Domain::UrlHost.authority(URI.parse("file:///tmp/notes.md"))
  end
end
