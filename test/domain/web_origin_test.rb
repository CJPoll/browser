require 'minitest/autorun'
require_relative '../../lib/domain/web_origin'

class WebOriginTest < Minitest::Test
  # --- from_url ---

  def test_keeps_only_the_scheme_and_host
    assert_equal 'https://example.com', Domain::WebOrigin.from_url('https://example.com/path?q=1#frag')
  end

  def test_drops_the_default_port
    assert_equal 'https://example.com', Domain::WebOrigin.from_url('https://example.com:443/')
    assert_equal 'http://example.com', Domain::WebOrigin.from_url('http://example.com:80/')
  end

  def test_keeps_a_non_default_port
    assert_equal 'https://example.com:8443', Domain::WebOrigin.from_url('https://example.com:8443/')
  end

  def test_lowercases_the_scheme_and_host
    assert_equal 'https://example.com', Domain::WebOrigin.from_url('HTTPS://Example.COM/Path')
  end

  def test_has_no_origin_for_a_missing_url
    assert_nil Domain::WebOrigin.from_url(nil)
  end

  def test_has_no_origin_for_a_non_http_url
    assert_nil Domain::WebOrigin.from_url('about:blank')
    assert_nil Domain::WebOrigin.from_url('file:///tmp/page.html')
  end

  def test_has_no_origin_for_a_malformed_url
    assert_nil Domain::WebOrigin.from_url('http://[bad')
  end

  # --- host ---

  def test_names_the_host_of_an_origin
    assert_equal 'example.com', Domain::WebOrigin.host('https://example.com:8443')
  end

  def test_has_no_host_for_a_missing_origin
    assert_nil Domain::WebOrigin.host(nil)
  end

  # --- secure? ---

  def test_https_is_secure
    assert Domain::WebOrigin.secure?('https://example.com')
  end

  def test_plain_http_is_not_secure
    refute Domain::WebOrigin.secure?('http://example.com')
  end

  def test_http_on_localhost_is_secure_for_development
    assert Domain::WebOrigin.secure?('http://localhost:3000')
    assert Domain::WebOrigin.secure?('http://app.localhost')
    assert Domain::WebOrigin.secure?('http://127.0.0.1:8080')
  end

  def test_a_missing_origin_is_not_secure
    refute Domain::WebOrigin.secure?(nil)
  end
end
