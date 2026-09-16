# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/handlers/login_fill_handler'
require_relative '../../lib/domain/login_candidate'
require_relative '../../lib/domain/login_credential'
require_relative '../../lib/domain/login_fill_prompt'
require_relative '../../lib/domain/login_fill_notice'
require_relative '../../lib/domain/login_form_js'

class HandlersLoginFillHandlerTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  FAKE_USERNAME = 'cody@example.com'
  ORIGIN = 'https://accounts.google.com'
  PROBE_JSON = JSON.generate(top: true, password: true, username: true)

  class FakeWebView
    Result = Struct.new(:value) { def to_s = value.to_s }

    attr_accessor :uri
    attr_reader :evaluations

    def initialize(uri: 'https://real.example/x')
      @uri = uri
      @evaluations = []
      @blocks = []
    end

    def evaluate_javascript(script, _length, world, _source_uri, _cancellable, &block)
      @evaluations << { script: script, world: world }
      @blocks << block
    end

    def complete_last(json)
      @finish = json
      @blocks.last.call(self, :result)
    end

    def evaluate_javascript_finish(_result)
      Result.new(@finish)
    end
  end

  class SpyManager
    attr_reader :prepare_args, :credential_args, :conclude_args

    def initialize(prepare: nil, credential: nil, conclude: nil)
      @prepare = prepare
      @credential = credential
      @conclude = conclude
      @prepare_args = []
      @credential_args = []
      @conclude_args = []
    end

    def prepare(origin:, probe_json:)
      @prepare_args << { origin: origin, probe_json: probe_json }
      resolve(@prepare)
    end

    def credential_for(prompt, index, live_origin:)
      @credential_args << { prompt: prompt, index: index, live_origin: live_origin }
      resolve(@credential)
    end

    def conclude(report_json)
      @conclude_args << report_json
      resolve(@conclude)
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end

  def candidate
    Domain::LoginCandidate.new(item_id: 'i', vault_id: 'v', title: 'Google', username: FAKE_USERNAME, urls: ['https://google.com'])
  end

  def prompt
    Domain::LoginFillPrompt.new(origin: ORIGIN, site_key: 'google.com', candidates: [candidate])
  end

  def credential
    Domain::LoginCredential.new(username: FAKE_USERNAME, password: FAKE_PASSWORD)
  end

  def notice(reason = :no_login_form)
    Domain::LoginFillNotice.new(reason: reason)
  end

  def build_handler(**spy_args)
    @shown_prompts = []
    @shown_notices = []
    @manager = SpyManager.new(**spy_args)
    LoginFillHandler.new(
      {
        show_prompt: ->(prompt, on_fill:, on_cancel:) { @shown_prompts << { prompt: prompt, on_fill: on_fill, on_cancel: on_cancel } },
        show_notice: ->(notice) { @shown_notices << notice }
      },
      manager: @manager
    )
  end

  def setup
    @webview = FakeWebView.new(uri: 'https://real.example/x')
  end

  # Runs the block capturing output and asserting the secret never leaks.
  def quietly
    out, err = capture_io { yield }
    refute_includes out, FAKE_PASSWORD
    refute_includes err, FAKE_PASSWORD
    [out, err]
  end

  def test_trigger_evaluates_the_probe_in_the_isolated_world
    handler = build_handler(prepare: prompt)

    quietly { handler.fill_current(@webview) }

    assert_equal 1, @webview.evaluations.length
    assert_equal Domain::LoginFormJs.probe_script, @webview.evaluations.first[:script]
    assert_equal LoginFillHandler::WORLD_NAME, @webview.evaluations.first[:world]
  end

  def test_probe_result_reaches_the_manager_with_the_browsers_origin
    handler = build_handler(prepare: prompt)
    @webview.uri = 'https://real.example/x?claimed=https://other.example'

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
    end

    assert_equal 'https://real.example', @manager.prepare_args.first[:origin]
    assert_equal PROBE_JSON, @manager.prepare_args.first[:probe_json]
  end

  def test_prompt_outcome_shows_the_bar_without_filling
    handler = build_handler(prepare: prompt)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
    end

    assert_equal [prompt], @shown_prompts.map { |s| s[:prompt] }
    assert_equal 1, @webview.evaluations.length, 'no fill script until the user confirms'
  end

  def test_notice_outcome_shows_the_notice_and_releases
    handler = build_handler(prepare: notice)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      handler.fill_current(@webview) # released, so this re-evaluates
    end

    assert_equal [notice], @shown_notices
    assert_equal 2, @webview.evaluations.length
  end

  def test_on_fill_asks_for_the_credential_with_the_live_origin
    handler = build_handler(prepare: prompt, credential: notice(:origin_changed))

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @webview.uri = 'https://changed.example/'
      @shown_prompts.first[:on_fill].call(0)
    end

    assert_equal 'https://changed.example', @manager.credential_args.first[:live_origin]
    assert_equal 0, @manager.credential_args.first[:index]
  end

  def test_credential_outcome_evaluates_the_fill_script
    handler = build_handler(prepare: prompt, credential: credential)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_fill].call(0)
    end

    assert_equal 2, @webview.evaluations.length
    fill = @webview.evaluations.last
    assert_equal LoginFillHandler::WORLD_NAME, fill[:world]
    assert_equal Domain::LoginFormJs.fill_call(credential, origin: prompt.origin), fill[:script]
  end

  def test_report_is_concluded_and_released
    handler = build_handler(prepare: prompt, credential: credential, conclude: nil)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_fill].call(0)
      @webview.complete_last(JSON.generate(ok: true))
      handler.fill_current(@webview) # released, re-evaluates
    end

    assert_equal [JSON.generate(ok: true)], @manager.conclude_args
    assert_equal 3, @webview.evaluations.length
  end

  def test_fill_failure_shows_a_notice
    handler = build_handler(prepare: prompt, credential: credential, conclude: notice(:fill_failed))

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_fill].call(0)
      @webview.complete_last(JSON.generate(ok: false, reason: 'no_password_field'))
    end

    assert_equal [notice(:fill_failed)], @shown_notices
  end

  def test_second_trigger_while_pending_is_ignored
    handler = build_handler(prepare: prompt)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      handler.fill_current(@webview) # ignored: prompt is still up
    end

    assert_equal 1, @webview.evaluations.length
    assert_equal 1, @manager.prepare_args.length
  end

  def test_cancel_releases
    handler = build_handler(prepare: prompt)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_cancel].call
      handler.fill_current(@webview)
    end

    assert_equal 2, @webview.evaluations.length
  end

  def test_script_error_releases_and_logs_the_class_only
    handler = build_handler(prepare: -> { raise RuntimeError, FAKE_PASSWORD })

    _out, err = capture_io do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      handler.fill_current(@webview) # released after the error, so re-evaluates
    end

    assert_match(/Login fill script failed: RuntimeError/, err)
    refute_includes err, FAKE_PASSWORD
    assert_equal 2, @webview.evaluations.length
  end

  def test_handler_holds_no_credential_after_a_fill
    handler = build_handler(prepare: prompt, credential: credential, conclude: nil)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_fill].call(0)
      @webview.complete_last(JSON.generate(ok: true))
    end

    holds_secret = handler.instance_variables.any? do |name|
      handler.instance_variable_get(name).respond_to?(:password)
    end
    refute holds_secret, 'the handler must not retain anything password-shaped'
  end

  def test_full_flow_prints_nothing_containing_the_secret
    handler = build_handler(prepare: prompt, credential: credential, conclude: nil)

    quietly do
      handler.fill_current(@webview)
      @webview.complete_last(PROBE_JSON)
      @shown_prompts.first[:on_fill].call(0)
      @webview.complete_last(JSON.generate(ok: true))
    end
  end
end
