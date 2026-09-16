# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/domain/login_candidate'

class DomainLoginCandidateTest < Minitest::Test
  def build(**overrides)
    Domain::LoginCandidate.new(**{
      item_id: 'abc123', vault_id: 'vlt456', title: 'GitHub',
      username: 'cody@example.com', urls: ['https://github.com/login']
    }.merge(overrides))
  end

  def test_requires_item_id
    error = assert_raises(ArgumentError) { build(item_id: nil) }
    assert_match(/item_id/, error.message)
  end

  def test_requires_vault_id
    error = assert_raises(ArgumentError) { build(vault_id: '') }
    assert_match(/vault_id/, error.message)
  end

  def test_requires_title
    error = assert_raises(ArgumentError) { build(title: nil) }
    assert_match(/title/, error.message)
  end

  def test_label_with_username
    assert_equal 'GitHub (cody@example.com)', build.label
  end

  def test_label_without_username
    assert_equal 'GitHub', build(username: nil).label
    assert_equal 'GitHub', build(username: '').label
  end

  def test_has_no_password
    refute_respond_to build, :password
  end

  def test_value_equality_and_with
    assert_equal build, build
    refute_equal build, build(urls: ['https://example.com'])
    assert_equal build(title: 'GitLab'), build.with(title: 'GitLab')
    refute_equal build, build.with(title: 'GitLab')
  end

  def test_urls_are_frozen_against_later_mutation
    urls = ['https://github.com/login']
    candidate = build(urls: urls)
    urls << 'https://evil.example'

    assert_equal ['https://github.com/login'], candidate.urls
    assert_predicate candidate.urls, :frozen?
  end

  def test_username_may_be_nil
    assert_nil build(username: nil).username
  end
end
