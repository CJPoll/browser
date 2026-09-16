# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/domain/login_site_match'
require_relative '../../lib/domain/login_candidate'

class DomainLoginSiteMatchTest < Minitest::Test
  def candidate(urls)
    Domain::LoginCandidate.new(item_id: 'i', vault_id: 'v', title: 't', urls: urls)
  end

  # --- site_key ---

  def test_etld_plus_one_of_a_subdomain
    assert_equal 'google.com', Domain::LoginSiteMatch.site_key('accounts.google.com')
  end

  def test_multi_label_public_suffix
    assert_equal 'amazon.co.uk', Domain::LoginSiteMatch.site_key('www.amazon.co.uk')
  end

  def test_private_registry_suffix_stays
    assert_equal 'foo.github.io', Domain::LoginSiteMatch.site_key('foo.github.io')
  end

  def test_multi_label_registry_suffix
    assert_equal 'microsoftonline.com', Domain::LoginSiteMatch.site_key('login.microsoftonline.com')
  end

  def test_loopback_and_ips_fall_back_to_the_host
    assert_equal 'localhost', Domain::LoginSiteMatch.site_key('localhost')
    assert_equal '127.0.0.1', Domain::LoginSiteMatch.site_key('127.0.0.1')
  end

  def test_unlisted_tld_falls_back
    assert_equal 'intranet', Domain::LoginSiteMatch.site_key('intranet')
    assert_equal 'myapp.local', Domain::LoginSiteMatch.site_key('myapp.local')
  end

  def test_case_and_trailing_dot
    assert_equal 'google.com', Domain::LoginSiteMatch.site_key('Accounts.Google.COM.')
  end

  def test_nil_host
    assert_nil Domain::LoginSiteMatch.site_key(nil)
  end

  # --- candidates_for ---

  def matched?(url, origin)
    Domain::LoginSiteMatch.candidates_for(origin: origin, candidates: [candidate([url])]).any?
  end

  def test_stored_url_with_scheme_and_path_matches
    assert matched?('https://google.com/login', 'https://accounts.google.com')
  end

  def test_bare_stored_host_matches
    assert matched?('github.com', 'https://github.com')
  end

  def test_different_registrable_domain_does_not
    refute matched?('https://google.com.evil.example', 'https://accounts.google.com')
  end

  def test_public_suffix_never_matches_by_suffix_alone
    refute matched?('https://co.uk', 'https://amazon.co.uk')
  end

  def test_candidate_with_no_urls
    refute Domain::LoginSiteMatch.candidates_for(origin: 'https://github.com', candidates: [candidate([])]).any?
  end

  def test_unparsable_url_does_not_raise_and_does_not_match
    refute matched?('not a url', 'https://github.com')
    refute matched?('mailto:x', 'https://github.com')
  end

  def test_nil_origin
    assert_equal [], Domain::LoginSiteMatch.candidates_for(origin: nil, candidates: [candidate(['github.com'])])
  end

  def test_order_is_preserved
    a = Domain::LoginCandidate.new(item_id: '1', vault_id: 'v', title: 'A', urls: ['https://github.com'])
    b = Domain::LoginCandidate.new(item_id: '2', vault_id: 'v', title: 'B', urls: ['https://example.com'])
    c = Domain::LoginCandidate.new(item_id: '3', vault_id: 'v', title: 'C', urls: ['github.com/login'])

    matches = Domain::LoginSiteMatch.candidates_for(origin: 'https://github.com', candidates: [a, b, c])

    assert_equal %w[A C], matches.map(&:title)
  end
end
