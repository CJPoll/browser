# frozen_string_literal: true

require 'webkit2-gtk'
require_relative '../javascript_core'
require_relative '../managers/passkey_manager'
require_relative '../domain/passkey_shim_js'
require_relative '../domain/passkey_request'
require_relative '../domain/passkey_prompt'
require_relative '../domain/passkey_response'
require_relative '../domain/web_origin'

# Gives pages a working `navigator.credentials` and answers what they ask
# of it.
#
# Framework: it injects the shim into each webview, receives the shim's
# messages, works out the page's real origin, and evaluates the reply. What
# a request means, and whether to grant it, is `Managers::PasskeyManager`'s
# business; showing the consent bar is the window's, reached through the
# `show_prompt` callback.
#
# Thread Safety: Assumes single-threaded GTK main loop execution.
class PasskeyHandler
  HANDLER_NAME = Domain::PasskeyShimJs::HANDLER_NAME
  ALREADY_PENDING = 'A passkey request is already pending'

  # @param callbacks [Hash] `show_prompt: ->(prompt, on_allow:, on_cancel:)`,
  #   where `on_allow` takes the index of the chosen candidate (0 when there
  #   is nothing to choose) and `on_cancel` takes nothing. Both return the
  #   `Domain::PasskeyResponse` that was delivered to the page, so the caller
  #   can tell a passkey that was made from one the store refused.
  # @param manager [Managers::PasskeyManager]
  def initialize(callbacks, manager: Managers::PasskeyManager.new)
    @callbacks = callbacks
    @manager = manager

    # Webviews with a prompt on screen, keyed by object id. A page that asks
    # again before the user has answered gets a refusal rather than a second
    # bar; the id is the key because the widget must not be held here.
    @pending = {}
  end

  # Injects the shim into a webview and listens for its messages
  #
  # @param webview [WebKit2Gtk::WebView] A webview with its own
  #   UserContentManager
  # @return [void]
  def attach(webview)
    content = webview.user_content_manager
    content.add_script(WebKit2Gtk::UserScript.new(
      Domain::PasskeyShimJs.script,
      # Top frame only: the origin is taken from the webview's own URI, which
      # is not the origin of an embedded frame.
      WebKit2Gtk::UserContentInjectedFrames::TOP_FRAME,
      WebKit2Gtk::UserScriptInjectionTime::START,
      nil, nil
    ))
    content.signal_connect("script-message-received::#{HANDLER_NAME}") do |_, result|
      handle_message(webview, result.js_value.to_s)
    end
    content.register_script_message_handler(HANDLER_NAME)
  end

  # Answers one message from the shim. The unit of work `attach` schedules;
  # public so it is testable without WebKit.
  #
  # @param webview [WebKit2Gtk::WebView] The webview the message came from
  # @param message [String] The JSON the shim posted
  # @return [void]
  def handle_message(webview, message)
    return refuse_while_pending(webview, message) if @pending[webview.object_id]

    outcome = @manager.prepare(message, origin: Domain::WebOrigin.from_url(webview.uri))
    case outcome
    when Domain::PasskeyPrompt then show_prompt(webview, outcome)
    when Domain::PasskeyResponse then deliver(webview, outcome)
    else warn 'Ignoring a passkey message with no request id'
    end
  end

  private

  def show_prompt(webview, prompt)
    @pending[webview.object_id] = true
    @callbacks[:show_prompt]&.call(
      prompt,
      on_allow: ->(choice) { deliver(webview, complete(prompt, choice)) },
      on_cancel: -> { deliver(webview, @manager.cancel(prompt)) }
    )
  end

  # @param choice [Integer] Index of the chosen candidate; irrelevant for creation
  # @return [Domain::PasskeyResponse]
  def complete(prompt, choice)
    if prompt.create?
      @manager.register(prompt)
    else
      @manager.authenticate(prompt, prompt.candidates.fetch(choice))
    end
  end

  def refuse_while_pending(webview, message)
    request_id = Domain::PasskeyRequest.request_id_of(message)
    return warn 'Ignoring a passkey message with no request id' unless request_id

    evaluate(webview, Domain::PasskeyResponse.rejected(
      request_id: request_id, name: Domain::PasskeyResponse::NOT_ALLOWED, message: ALREADY_PENDING
    ))
  end

  # @return [Domain::PasskeyResponse] What was delivered
  def deliver(webview, response)
    @pending.delete(webview.object_id)
    evaluate(webview, response)
    response
  end

  # Settles the page's promise. No completion block: if the page has
  # navigated away there is nobody left to tell.
  def evaluate(webview, response)
    webview.evaluate_javascript(Domain::PasskeyShimJs.completion_call(response), -1, nil, nil, nil)
  end
end
