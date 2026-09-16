# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/managers/login_fill_manager'
require_relative '../../lib/adapters/one_password_cli'
require_relative '../../lib/domain/login_candidate'
require_relative '../../lib/domain/login_credential'
require_relative '../../lib/domain/login_fill_prompt'
require_relative '../../lib/domain/login_fill_notice'

class ManagersLoginFillManagerTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  PROBE_OK = JSON.generate(top: true, password: true, username: true)

  class FakeStore
    attr_reader :list_calls, :password_calls

    def initialize(candidates: [], password: FAKE_PASSWORD, failing: nil)
      @candidates = candidates
      @password = password
      @failing = failing
      @list_calls = 0
      @password_calls = 0
    end

    def list_logins
      @list_calls += 1
      raise_failure if @failing
      @candidates
    end

    def password_for(candidate)
      @password_calls += 1
      raise_failure if @failing
      Domain::LoginCredential.new(username: candidate.username, password: @password)
    end

    private

    def raise_failure
      case @failing
      when :not_installed then raise Adapters::OnePasswordCli::NotInstalled, 'op'
      when :not_signed_in then raise Adapters::OnePasswordCli::NotSignedIn, 'You are not currently signed in'
      when :timed_out then raise Adapters::OnePasswordCli::TimedOut, 'op did not answer in time'
      when :failed then raise Adapters::OnePasswordCli::Failed, 'boom'
      end
    end
  end

  def candidate(title: 'Google', username: 'cody@example.com', urls: ['https://google.com/login'], item_id: 'i1', vault_id: 'v1')
    Domain::LoginCandidate.new(item_id: item_id, vault_id: vault_id, title: title, username: username, urls: urls)
  end

  def manager(**store_args)
    @store = FakeStore.new(**store_args)
    Managers::LoginFillManager.new(store: @store)
  end

  # Wraps a call, returns its value, and asserts the secret never reached a
  # stream. Used around every path (spec 5.3).
  def quietly
    result = nil
    out, err = capture_io { result = yield }
    refute_includes out, FAKE_PASSWORD
    refute_includes err, FAKE_PASSWORD
    result
  end

  # --- prepare: gates ---

  def test_nil_origin
    m = manager
    result = quietly { m.prepare(origin: nil, probe_json: PROBE_OK) }

    assert_equal :no_origin, result.reason
    assert_equal 0, @store.list_calls
  end

  def test_http_non_loopback_is_insecure
    m = manager
    result = quietly { m.prepare(origin: 'http://example.com', probe_json: PROBE_OK) }

    assert_equal :insecure_origin, result.reason
    assert_equal 0, @store.list_calls
  end

  def test_loopback_http_allowed
    m = manager(candidates: [candidate(urls: ['http://localhost:3000'])])
    result = quietly { m.prepare(origin: 'http://localhost:3000', probe_json: PROBE_OK) }

    assert_instance_of Domain::LoginFillPrompt, result
  end

  def test_no_password_field
    m = manager
    result = quietly { m.prepare(origin: 'https://google.com', probe_json: JSON.generate(top: true, password: false)) }

    assert_equal :no_login_form, result.reason
    assert_equal 0, @store.list_calls
  end

  def test_not_top_document
    m = manager
    result = quietly { m.prepare(origin: 'https://google.com', probe_json: JSON.generate(top: false, password: true)) }

    assert_equal :no_login_form, result.reason
    assert_equal 0, @store.list_calls
  end

  def test_malformed_probe
    m = manager
    result = quietly { m.prepare(origin: 'https://google.com', probe_json: 'garbage') }

    assert_equal :no_login_form, result.reason
    assert_equal 0, @store.list_calls
  end

  # --- prepare: matching ---

  def test_no_matches
    m = manager(candidates: [candidate(urls: ['https://other.example'])])
    result = quietly { m.prepare(origin: 'https://accounts.google.com', probe_json: PROBE_OK) }

    assert_equal :no_matches, result.reason
    assert_equal 'google.com', result.detail
  end

  def test_single_match
    m = manager(candidates: [candidate])
    result = quietly { m.prepare(origin: 'https://accounts.google.com', probe_json: PROBE_OK) }

    assert_instance_of Domain::LoginFillPrompt, result
    refute result.choice_needed?
    assert_equal 'google.com', result.site_key
  end

  def test_several_matches_keep_order
    a = candidate(title: 'A', item_id: '1')
    b = candidate(title: 'B', item_id: '2', urls: ['https://other.example'])
    c = candidate(title: 'C', item_id: '3')
    m = manager(candidates: [a, b, c])

    result = quietly { m.prepare(origin: 'https://accounts.google.com', probe_json: PROBE_OK) }

    assert_equal %w[A C], result.candidates.map(&:title)
  end

  def test_store_errors_map_to_notices
    { not_installed: :not_installed, not_signed_in: :not_signed_in, timed_out: :timed_out, failed: :unavailable }.each do |failing, reason|
      m = manager(failing: failing)
      result = quietly { m.prepare(origin: 'https://google.com', probe_json: PROBE_OK) }

      assert_equal reason, result.reason
    end
  end

  def test_prepare_never_fetches_a_password
    m = manager(candidates: [candidate])
    quietly { m.prepare(origin: 'https://accounts.google.com', probe_json: PROBE_OK) }

    assert_equal 0, @store.password_calls
  end

  def test_logs_only_reasons_not_labels
    m = manager(failing: :not_signed_in)
    _out, err = capture_io { m.prepare(origin: 'https://google.com', probe_json: PROBE_OK) }

    assert_match(/Login fill: 1Password not_signed_in/, err)
    refute_includes err, 'signed in' # the exception message must not be logged
  end

  # --- credential_for ---

  def prompt_for(*candidates)
    Domain::LoginFillPrompt.new(origin: 'https://accounts.google.com', site_key: 'google.com', candidates: candidates)
  end

  def test_credential_for_fetches_the_chosen_one
    m = manager(candidates: [])
    prompt = prompt_for(candidate(title: 'A', item_id: '1'), candidate(title: 'B', item_id: '2'))

    credential = quietly { m.credential_for(prompt, 1, live_origin: prompt.origin) }

    assert_equal FAKE_PASSWORD, credential.password
    assert_equal 1, @store.password_calls
  end

  def test_origin_changed
    m = manager
    prompt = prompt_for(candidate)

    result = quietly { m.credential_for(prompt, 0, live_origin: 'https://evil.example') }

    assert_equal :origin_changed, result.reason
    assert_equal 0, @store.password_calls
  end

  def test_index_outside_the_prompt_raises_without_fetching
    m = manager
    prompt = prompt_for(candidate)

    assert_raises(ArgumentError) { m.credential_for(prompt, 5, live_origin: prompt.origin) }
    assert_equal 0, @store.password_calls
  end

  def test_fetch_failure_maps_to_a_notice
    m = manager(failing: :not_signed_in)
    prompt = prompt_for(candidate)

    result = quietly { m.credential_for(prompt, 0, live_origin: prompt.origin) }

    assert_equal :not_signed_in, result.reason
  end

  # --- conclude ---

  def test_conclude_filled
    m = manager
    assert_nil(quietly { m.conclude(JSON.generate(ok: true, username: true, password: true)) })
  end

  def test_conclude_failed
    m = manager
    result = quietly { m.conclude(JSON.generate(ok: false, reason: 'no_password_field')) }

    assert_equal :fill_failed, result.reason
    assert_equal 'no_password_field', result.detail
  end

  def test_conclude_malformed
    m = manager
    result = quietly { m.conclude('x') }

    assert_equal :fill_failed, result.reason
    assert_equal 'unreadable_report', result.detail
  end
end
