# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/managers/login_fill_manager'
require_relative '../../lib/adapters/one_password_login_store'
require_relative '../../lib/adapters/one_password_cli'
require_relative '../../lib/domain/login_form_js'
require_relative '../../lib/domain/login_fill_prompt'
require_relative '../../lib/domain/login_fill_notice'

# The whole use case with real Domain, real OnePasswordLoginStore, real
# OnePasswordCli and real manager -- only the process runner is faked, so the
# `op` invocations the feature would make are observable and no real `op` runs.
class LoginFillFlowTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  ORIGIN = 'https://github.com'
  PROBE_OK = JSON.generate(top: true, origin: ORIGIN, password: true, username: true)

  LIST_ARGV = %w[op item list --categories Login --format json].freeze

  class RecordingRunner
    Status = Struct.new(:success?)

    attr_reader :invocations

    def initialize(results = [])
      @results = results
      @invocations = []
    end

    def call(*argv, timeout:)
      @invocations << argv
      stdout, stderr, success = @results.shift || ['', '', true]
      [stdout, stderr, Status.new(success)]
    end
  end

  def item_list_json
    JSON.generate([{
      'id' => 'abc123', 'title' => 'GitHub',
      'vault' => { 'id' => 'vlt456', 'name' => 'Private' },
      'category' => 'LOGIN', 'additional_information' => 'cody@example.com',
      'urls' => [{ 'href' => 'https://github.com/login' }]
    }])
  end

  def manager_with(*results)
    @runner = RecordingRunner.new(results)
    store = Adapters::OnePasswordLoginStore.new(cli: Adapters::OnePasswordCli.new(runner: @runner))
    Managers::LoginFillManager.new(store: store)
  end

  def test_no_form_makes_no_op_invocation
    manager = manager_with
    notice = manager.prepare(origin: ORIGIN, probe_json: JSON.generate(top: true, password: false))

    assert_equal :no_login_form, notice.reason
    assert_empty @runner.invocations
  end

  def test_prepare_lists_once_and_reads_nothing
    manager = manager_with([item_list_json, '', true])
    prompt = manager.prepare(origin: ORIGIN, probe_json: PROBE_OK)

    assert_instance_of Domain::LoginFillPrompt, prompt
    assert_equal [LIST_ARGV], @runner.invocations
  end

  def test_confirm_reads_exactly_the_chosen_item
    manager = manager_with([item_list_json, '', true], [FAKE_PASSWORD, '', true])
    prompt = manager.prepare(origin: ORIGIN, probe_json: PROBE_OK)

    credential = manager.credential_for(prompt, 0, live_origin: ORIGIN)

    assert_equal FAKE_PASSWORD, credential.password
    assert_equal [LIST_ARGV, %w[op read --no-newline op://vlt456/abc123/password]], @runner.invocations
  end

  def test_the_fill_call_carries_the_credential_and_nothing_is_printed
    manager = manager_with([item_list_json, '', true], [FAKE_PASSWORD, '', true])

    out, err = capture_io do
      prompt = manager.prepare(origin: ORIGIN, probe_json: PROBE_OK)
      credential = manager.credential_for(prompt, 0, live_origin: ORIGIN)
      call = Domain::LoginFormJs.fill_call(credential, origin: prompt.origin)
      argument = call.delete_prefix("#{Domain::LoginFormJs::FILL}(").delete_suffix(');')

      assert_equal FAKE_PASSWORD, JSON.parse(argument)['password']
    end

    refute_includes out, FAKE_PASSWORD
    refute_includes err, FAKE_PASSWORD
  end

  def test_locked_vault_ends_in_a_notice_after_one_invocation
    manager = manager_with(['', 'You are not currently signed in', false])

    notice = nil
    capture_io { notice = manager.prepare(origin: ORIGIN, probe_json: PROBE_OK) }

    assert_equal :not_signed_in, notice.reason
    assert_equal 1, @runner.invocations.length
  end
end
