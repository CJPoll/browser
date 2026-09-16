require 'minitest/autorun'
require 'json'
require_relative '../../lib/handlers/passkey_handler'
require_relative '../../lib/domain/passkey_request'
require_relative '../../lib/domain/passkey_prompt'
require_relative '../../lib/domain/passkey_response'
require_relative '../../lib/domain/passkey'
require_relative '../../lib/domain/passkey_shim_js'

class HandlersPasskeyHandlerTest < Minitest::Test
  PAGE_URL = 'https://accounts.example.com/signin?next=%2F'.freeze
  ORIGIN = 'https://accounts.example.com'.freeze
  NOW = Time.at(1_700_000_000).freeze

  # The handler asks a webview for its URI, hands it a user content manager
  # to attach to, and evaluates JavaScript in it.
  class FakeContentManager
    attr_reader :scripts, :registered, :connected

    def initialize
      @scripts = []
      @registered = []
      @connected = {}
    end

    def add_script(script)
      @scripts << script
    end

    def register_script_message_handler(name)
      @registered << name
      true
    end

    def signal_connect(name, &block)
      @connected[name] = block
    end
  end

  class FakeWebView
    attr_accessor :uri
    attr_reader :evaluated, :user_content_manager

    def initialize(uri: PAGE_URL)
      @uri = uri
      @evaluated = []
      @user_content_manager = FakeContentManager.new
    end

    def evaluate_javascript(script, *_rest)
      @evaluated << script
    end
  end

  # Stands in for Managers::PasskeyManager: answers `prepare` with whatever
  # it was built with, and records the rest.
  class SpyManager
    attr_reader :prepared, :registered, :authenticated, :cancelled

    def initialize(outcome:)
      @outcome = outcome
      @prepared = []
      @registered = []
      @authenticated = []
      @cancelled = []
    end

    def prepare(message, origin:)
      @prepared << [message, origin]
      @outcome
    end

    def register(prompt)
      @registered << prompt
      Domain::PasskeyResponse.rejected(request_id: prompt.request_id, name: 'NotAllowedError', message: 'registered')
    end

    def authenticate(prompt, passkey)
      @authenticated << [prompt, passkey]
      Domain::PasskeyResponse.rejected(request_id: prompt.request_id, name: 'NotAllowedError', message: 'authenticated')
    end

    def cancel(prompt)
      @cancelled << prompt
      Domain::PasskeyResponse.rejected(request_id: prompt.request_id, name: 'NotAllowedError', message: 'cancelled')
    end
  end

  def create_message(id: 'passkey-1')
    JSON.generate(
      'id' => id, 'op' => 'create',
      'options' => { 'challenge' => 'Y2hhbGxlbmdl', 'user' => { 'id' => 'dXNlcg', 'name' => 'cody@example.com' } }
    )
  end

  def get_message(id: 'passkey-2')
    JSON.generate('id' => id, 'op' => 'get', 'options' => { 'challenge' => 'Y2hhbGxlbmdl' })
  end

  def passkey(name)
    Domain::Passkey.new(credential_id: "id-#{name}", rp_id: 'accounts.example.com', user_handle: 'dXNlcg',
                        user_name: name, private_key_pem: 'pem', created_at: NOW)
  end

  def create_prompt
    Domain::PasskeyPrompt.new(request: Domain::PasskeyRequest.parse(create_message), origin: ORIGIN, rp_id: 'accounts.example.com')
  end

  def get_prompt(candidates)
    Domain::PasskeyPrompt.new(request: Domain::PasskeyRequest.parse(get_message), origin: ORIGIN,
                              rp_id: 'accounts.example.com', candidates: candidates)
  end

  def rejection(id: 'passkey-1')
    Domain::PasskeyResponse.rejected(request_id: id, name: 'SecurityError', message: 'refused')
  end

  def build_handler(outcome)
    @shown = []
    @manager = SpyManager.new(outcome: outcome)
    PasskeyHandler.new(
      { show_prompt: ->(prompt, on_allow:, on_cancel:) { @shown << { prompt: prompt, on_allow: on_allow, on_cancel: on_cancel } } },
      manager: @manager
    )
  end

  def setup
    @webview = FakeWebView.new
  end

  def delivered
    @webview.evaluated
  end

  def completion_of(response)
    Domain::PasskeyShimJs.completion_call(response)
  end

  # === attach ===

  def test_attach_injects_the_shim_and_registers_the_message_handler
    handler = build_handler(create_prompt)

    handler.attach(@webview)

    content = @webview.user_content_manager
    assert_equal 1, content.scripts.length
    assert_kind_of WebKit2Gtk::UserScript, content.scripts.first
    assert_equal ['passkey'], content.registered
    assert content.connected.key?('script-message-received::passkey')
  end

  # === handle_message ===

  def test_a_request_the_manager_wants_the_user_asked_about_is_shown
    handler = build_handler(create_prompt)

    handler.handle_message(@webview, create_message)

    assert_equal [create_prompt], @shown.map { |shown| shown[:prompt] }
    assert_empty delivered
  end

  def test_the_origin_comes_from_the_webview_not_the_page
    handler = build_handler(create_prompt)
    @webview.uri = 'https://real.example/path?claimed=https://other.example'

    handler.handle_message(@webview, create_message)

    assert_equal [[create_message, 'https://real.example']], @manager.prepared
  end

  def test_a_webview_with_no_origin_is_reported_as_such
    handler = build_handler(rejection)
    @webview.uri = 'about:blank'

    handler.handle_message(@webview, create_message)

    assert_nil @manager.prepared.first.last
  end

  def test_an_immediate_rejection_is_delivered_to_the_page
    handler = build_handler(rejection)

    handler.handle_message(@webview, create_message)

    assert_equal [completion_of(rejection)], delivered
    assert_empty @shown
  end

  def test_a_message_that_cannot_be_answered_is_ignored_with_a_warning
    handler = build_handler(nil)

    assert_output(nil, /passkey/i) { handler.handle_message(@webview, 'not json') }

    assert_empty delivered
    assert_empty @shown
  end

  # === answering a prompt ===

  def test_allowing_a_creation_prompt_registers_and_delivers_the_result
    handler = build_handler(create_prompt)
    handler.handle_message(@webview, create_message)

    response = @shown.first[:on_allow].call(0)

    assert_equal [create_prompt], @manager.registered
    assert_equal [completion_of(@manager.register(create_prompt))], delivered
    assert_equal @manager.register(create_prompt), response, 'the window is told what the page got'
  end

  def test_allowing_a_sign_in_prompt_authenticates_with_the_chosen_passkey
    prompt = get_prompt([passkey('cody@example.com'), passkey('work@example.com')])
    handler = build_handler(prompt)
    handler.handle_message(@webview, get_message)

    @shown.first[:on_allow].call(1)

    assert_equal [[prompt, passkey('work@example.com')]], @manager.authenticated
    assert_equal 1, delivered.length
  end

  def test_cancelling_a_prompt_delivers_the_refusal
    handler = build_handler(create_prompt)
    handler.handle_message(@webview, create_message)

    response = @shown.first[:on_cancel].call

    assert_equal [create_prompt], @manager.cancelled
    assert_equal [completion_of(@manager.cancel(create_prompt))], delivered
    assert_equal @manager.cancel(create_prompt), response
  end

  # === one request at a time per page ===

  def test_a_second_request_while_one_is_pending_is_refused_without_asking_the_manager
    handler = build_handler(create_prompt)
    handler.handle_message(@webview, create_message)

    handler.handle_message(@webview, get_message(id: 'passkey-2'))

    assert_equal 1, @manager.prepared.length
    assert_equal 1, @shown.length
    refusal = Domain::PasskeyResponse.rejected(request_id: 'passkey-2', name: 'NotAllowedError', message: 'A passkey request is already pending')
    assert_equal [completion_of(refusal)], delivered
  end

  def test_the_page_may_ask_again_once_the_pending_request_is_answered
    handler = build_handler(create_prompt)
    handler.handle_message(@webview, create_message)
    @shown.first[:on_cancel].call

    handler.handle_message(@webview, create_message)

    assert_equal 2, @manager.prepared.length
    assert_equal 2, @shown.length
  end

  def test_pending_requests_are_per_webview
    handler = build_handler(create_prompt)
    other = FakeWebView.new
    handler.handle_message(@webview, create_message)

    handler.handle_message(other, create_message)

    assert_equal 2, @shown.length
  end

  def test_a_second_request_with_no_id_while_one_is_pending_is_ignored
    handler = build_handler(create_prompt)
    handler.handle_message(@webview, create_message)

    assert_output(nil, /passkey/i) { handler.handle_message(@webview, 'not json') }

    assert_empty delivered
  end
end
