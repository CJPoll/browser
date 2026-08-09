require 'minitest/autorun'
require_relative '../../lib/domain/permission_decision'

class PermissionDecisionTest < Minitest::Test
  def test_a_site_that_already_holds_the_permission_is_allowed
    decision = Domain::PermissionDecision.for(url: 'https://meet.example.com/room', granted: true)

    assert_equal :allow, decision.action
    assert_equal 'meet.example.com', decision.host
  end

  def test_a_site_that_does_not_hold_the_permission_is_prompted_for
    decision = Domain::PermissionDecision.for(url: 'https://meet.example.com/room', granted: false)

    assert_equal :prompt, decision.action
    assert_equal 'meet.example.com', decision.host
  end

  def test_a_url_without_a_host_is_ignored
    # Nothing to key a permission on, so the request is left for WebKit.
    decision = Domain::PermissionDecision.for(url: 'about:blank', granted: false)

    assert_equal :ignore, decision.action
    assert_nil decision.host
  end

  def test_a_malformed_url_is_ignored
    decision = Domain::PermissionDecision.for(url: 'http://[bad', granted: false)

    assert_equal :ignore, decision.action
    assert_nil decision.host
  end

  def test_a_missing_url_is_ignored
    decision = Domain::PermissionDecision.for(url: nil, granted: false)

    assert_equal :ignore, decision.action
    assert_nil decision.host
  end

  def test_a_host_less_url_is_ignored_even_when_the_permission_is_granted
    # A grant cannot exist without a host, but the decision must not claim one.
    decision = Domain::PermissionDecision.for(url: nil, granted: true)

    assert_equal :ignore, decision.action
  end

  def test_the_port_is_not_part_of_the_host
    decision = Domain::PermissionDecision.for(url: 'https://localhost:8443/app', granted: true)

    assert_equal 'localhost', decision.host
  end

  # --- Value semantics ---

  def test_decisions_with_the_same_attributes_are_equal
    first = Domain::PermissionDecision.for(url: 'https://example.com', granted: true)
    second = Domain::PermissionDecision.for(url: 'https://example.com', granted: true)

    assert_equal first, second
    assert_equal first.hash, second.hash
  end

  def test_decisions_differing_in_action_are_not_equal
    granted = Domain::PermissionDecision.for(url: 'https://example.com', granted: true)
    prompted = Domain::PermissionDecision.for(url: 'https://example.com', granted: false)

    refute_equal granted, prompted
  end

  def test_a_decision_is_not_equal_to_a_lookalike_hash
    decision = Domain::PermissionDecision.for(url: 'https://example.com', granted: true)

    refute_equal decision, decision.to_h
  end

  def test_to_h_exposes_every_attribute
    decision = Domain::PermissionDecision.for(url: 'https://example.com', granted: true)

    assert_equal({ action: :allow, host: 'example.com' }, decision.to_h)
  end

  def test_action_is_required
    error = assert_raises(ArgumentError) { Domain::PermissionDecision.new(action: nil) }

    assert_match(/action/, error.message)
  end
end
