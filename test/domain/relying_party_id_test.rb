require 'minitest/autorun'
require_relative '../../lib/domain/relying_party_id'

class RelyingPartyIdTest < Minitest::Test
  ORIGIN = 'https://accounts.google.com'.freeze

  def resolve(origin: ORIGIN, requested: nil)
    Domain::RelyingPartyId.resolve(origin: origin, requested: requested)
  end

  def test_defaults_to_the_origin_host_when_the_site_asks_for_nothing
    result = resolve

    assert result.valid?
    assert_equal 'accounts.google.com', result.rp_id
  end

  def test_an_empty_request_is_the_same_as_none
    assert_equal 'accounts.google.com', resolve(requested: '').rp_id
  end

  def test_accepts_the_origin_host_itself
    assert_equal 'accounts.google.com', resolve(requested: 'accounts.google.com').rp_id
  end

  def test_accepts_a_registrable_parent_domain
    # This is the case that lets one passkey serve every google.com subdomain.
    assert_equal 'google.com', resolve(requested: 'google.com').rp_id
  end

  def test_compares_the_requested_id_case_insensitively
    assert_equal 'google.com', resolve(requested: 'Google.COM').rp_id
  end

  def test_refuses_a_public_suffix
    # co.uk is a suffix of the host, but a passkey scoped to it would serve
    # every site in the UK.
    result = resolve(origin: 'https://bank.example.co.uk', requested: 'co.uk')

    refute result.valid?
    assert_equal :public_suffix, result.error
    assert_nil result.rp_id
  end

  def test_refuses_a_private_registry_suffix
    result = resolve(origin: 'https://someone.github.io', requested: 'github.io')

    assert_equal :public_suffix, result.error
  end

  def test_accepts_a_registrable_domain_under_a_multi_label_suffix
    assert_equal 'example.co.uk', resolve(origin: 'https://bank.example.co.uk', requested: 'example.co.uk').rp_id
  end

  def test_refuses_an_unrelated_domain
    result = resolve(origin: 'https://evil.example', requested: 'google.com')

    assert_equal :not_a_suffix, result.error
  end

  def test_refuses_a_domain_that_only_shares_a_string_suffix
    # "notgoogle.com" ends with "google.com" but is not a subdomain of it.
    result = resolve(origin: 'https://notgoogle.com', requested: 'google.com')

    assert_equal :not_a_suffix, result.error
  end

  def test_refuses_a_plain_http_origin
    result = resolve(origin: 'http://accounts.google.com')

    assert_equal :insecure_origin, result.error
  end

  def test_refuses_a_missing_origin
    assert_equal :insecure_origin, resolve(origin: nil).error
  end

  def test_allows_localhost_over_http_for_development
    assert_equal 'localhost', resolve(origin: 'http://localhost:3000').rp_id
  end

  def test_ignores_the_origin_port
    assert_equal 'example.com', resolve(origin: 'https://example.com:8443').rp_id
  end

  # --- Value semantics ---

  def test_results_with_the_same_attributes_are_equal
    assert_equal resolve, resolve
    assert_equal resolve.hash, resolve.hash
  end

  def test_to_h_exposes_every_attribute
    assert_equal({ rp_id: 'accounts.google.com', error: nil }, resolve.to_h)
    assert_equal({ rp_id: nil, error: :insecure_origin }, resolve(origin: nil).to_h)
  end
end
