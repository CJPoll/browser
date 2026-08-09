require 'minitest/autorun'
require_relative '../../lib/domain/popup_decision'

class PopupDecisionTest < Minitest::Test
  # --- An allowed site ---

  def test_allowed_ordinary_url_opens_in_a_new_tab
    decision = Domain::PopupDecision.for(url: 'https://example.com/popup', allowed: true)

    assert_equal :new_tab, decision.action
    assert_equal 'https://example.com/popup', decision.url
    assert_equal 'example.com', decision.host
  end

  def test_allowed_oauth_url_opens_a_floating_window
    decision = Domain::PopupDecision.for(url: 'https://accounts.google.com/o/oauth2/auth', allowed: true)

    assert_equal :oauth_window, decision.action
    assert_equal 'accounts.google.com', decision.host
  end

  def test_allowed_github_oauth_url_opens_a_floating_window
    decision = Domain::PopupDecision.for(url: 'https://github.com/login/oauth/authorize', allowed: true)

    assert_equal :oauth_window, decision.action
  end

  def test_allowed_ordinary_github_url_opens_in_a_new_tab
    decision = Domain::PopupDecision.for(url: 'https://github.com/cjpoll/browser', allowed: true)

    assert_equal :new_tab, decision.action
  end

  # --- A site that has not been allowed ---

  def test_blocked_url_prompts_the_user
    decision = Domain::PopupDecision.for(url: 'https://ads.example.com/popup', allowed: false)

    assert_equal :prompt, decision.action
    assert_equal 'ads.example.com', decision.host
    assert_equal 'https://ads.example.com/popup', decision.url
  end

  def test_blocked_oauth_url_still_prompts_rather_than_opening
    decision = Domain::PopupDecision.for(url: 'https://accounts.google.com/o/oauth2/auth', allowed: false)

    assert_equal :prompt, decision.action
  end

  # --- Nothing usable to open ---

  def test_no_url_is_blocked_without_prompting
    decision = Domain::PopupDecision.for(url: nil, allowed: false)

    assert_equal :block, decision.action
    assert_nil decision.url
    assert_nil decision.host
  end

  def test_no_url_is_blocked_even_when_the_site_is_allowed
    decision = Domain::PopupDecision.for(url: nil, allowed: true)

    assert_equal :block, decision.action
  end

  def test_blocked_url_without_a_host_cannot_be_prompted_for
    # There is no host to grant a permission to, so the popup is dropped
    # silently -- the bar would have nothing to name.
    decision = Domain::PopupDecision.for(url: 'about:blank', allowed: false)

    assert_equal :block, decision.action
    assert_nil decision.host
  end

  def test_malformed_url_is_blocked_without_prompting
    decision = Domain::PopupDecision.for(url: 'http://[bad', allowed: false)

    assert_equal :block, decision.action
    assert_nil decision.host
  end

  def test_empty_url_is_blocked_without_prompting
    decision = Domain::PopupDecision.for(url: '', allowed: false)

    assert_equal :block, decision.action
  end

  # --- Value semantics ---

  def test_decisions_with_the_same_attributes_are_equal
    first = Domain::PopupDecision.for(url: 'https://example.com', allowed: true)
    second = Domain::PopupDecision.for(url: 'https://example.com', allowed: true)

    assert_equal first, second
    assert_equal first.hash, second.hash
  end

  def test_decisions_differing_in_action_are_not_equal
    allowed = Domain::PopupDecision.for(url: 'https://example.com', allowed: true)
    blocked = Domain::PopupDecision.for(url: 'https://example.com', allowed: false)

    refute_equal allowed, blocked
  end

  def test_a_decision_is_not_equal_to_a_lookalike_hash
    decision = Domain::PopupDecision.for(url: 'https://example.com', allowed: true)

    refute_equal decision, decision.to_h
  end

  def test_to_h_exposes_every_attribute
    decision = Domain::PopupDecision.for(url: 'https://example.com', allowed: true)

    assert_equal({ action: :new_tab, url: 'https://example.com', host: 'example.com' }, decision.to_h)
  end

  def test_action_is_required
    error = assert_raises(ArgumentError) { Domain::PopupDecision.new(action: nil) }

    assert_match(/action/, error.message)
  end
end
