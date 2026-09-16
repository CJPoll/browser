# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/domain/login_fill_prompt'
require_relative '../../lib/domain/login_candidate'

class DomainLoginFillPromptTest < Minitest::Test
  def candidate(title, username = nil)
    Domain::LoginCandidate.new(item_id: title, vault_id: 'v', title: title, username: username, urls: ['https://google.com'])
  end

  def build(candidates)
    Domain::LoginFillPrompt.new(origin: 'https://accounts.google.com', site_key: 'google.com', candidates: candidates)
  end

  def test_requires_non_empty_candidates
    assert_raises(ArgumentError) { build([]) }
  end

  def test_choice_needed_for_one_vs_two
    refute build([candidate('A')]).choice_needed?
    assert build([candidate('A'), candidate('B')]).choice_needed?
  end

  def test_candidate_labels
    prompt = build([candidate('GitHub', 'cody@example.com'), candidate('Work')])

    assert_equal ['GitHub (cody@example.com)', 'Work'], prompt.candidate_labels
  end

  def test_candidate_at_valid
    prompt = build([candidate('A'), candidate('B')])

    assert_equal 'B', prompt.candidate_at(1).title
  end

  def test_candidate_at_out_of_range
    prompt = build([candidate('A')])

    assert_raises(ArgumentError) { prompt.candidate_at(1) }
    assert_raises(ArgumentError) { prompt.candidate_at(-1) }
    assert_raises(ArgumentError) { prompt.candidate_at(1.5) }
    assert_raises(ArgumentError) { prompt.candidate_at('0') }
  end

  def test_message_single
    prompt = build([candidate('GitHub', 'cody@example.com')])

    assert_equal 'Fill the login for google.com with GitHub (cody@example.com)?', prompt.message
  end

  def test_message_several
    prompt = build([candidate('A'), candidate('B')])

    assert_equal 'Fill the login for google.com -- choose an account', prompt.message
  end

  def test_equality
    assert_equal build([candidate('A')]), build([candidate('A')])
    refute_equal build([candidate('A')]), build([candidate('B')])
  end
end
