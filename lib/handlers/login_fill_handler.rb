# frozen_string_literal: true

require 'set'
require_relative '../javascript_core'
require_relative '../managers/login_fill_manager'
require_relative '../domain/login_form_js'
require_relative '../domain/login_fill_prompt'
require_relative '../domain/login_fill_notice'
require_relative '../domain/web_origin'

# Framework: triggers a login fill, evaluates the probe and fill scripts in the
# webview's isolated world, reads the results, and drives the consent bar
# through callbacks. What a probe means, whether to offer, and when to fetch the
# secret is Managers::LoginFillManager's business; showing the bar is the
# window's, reached through the `show_prompt` / `show_notice` callbacks.
#
# The origin always comes from the webview's own URI, never from anything the
# page reported. Only one flow runs per tab at a time, keyed by object id so no
# webview is held here.
#
# Thread Safety: assumes single-threaded GTK main loop execution.
class LoginFillHandler
  WORLD_NAME = Domain::LoginFormJs::WORLD_NAME
  ALREADY_PENDING = 'Login fill already pending for this tab'

  # @param callbacks [Hash] `show_prompt: ->(prompt, on_fill:, on_cancel:)`
  #   and `show_notice: ->(notice)`. `on_fill` takes the chosen candidate
  #   index; `on_cancel` takes nothing.
  # @param manager [Managers::LoginFillManager]
  def initialize(callbacks, manager: Managers::LoginFillManager.new)
    @callbacks = callbacks
    @manager = manager
    @pending = Set.new
  end

  # The trigger: probe the page, then decide. Ignored (with one log line) when
  # a flow is already up for this tab.
  #
  # @param webview [WebKit2Gtk::WebView]
  # @return [void]
  def fill_current(webview)
    if @pending.include?(webview.object_id)
      puts ALREADY_PENDING
      return
    end

    @pending << webview.object_id
    evaluate(webview, Domain::LoginFormJs.probe_script) { |json| handle_probe(webview, json) }
  end

  # Turns the probe result into a prompt shown to the user, or a notice.
  # Public so it is testable without WebKit.
  #
  # @param webview [WebKit2Gtk::WebView]
  # @param probe_json [String]
  # @return [void]
  def handle_probe(webview, probe_json)
    outcome = @manager.prepare(origin: Domain::WebOrigin.from_url(webview.uri), probe_json: probe_json)

    if outcome.is_a?(Domain::LoginFillPrompt)
      @callbacks[:show_prompt].call(
        outcome,
        on_fill: ->(index) { confirm(webview, outcome, index) },
        on_cancel: -> { release(webview); puts "Login fill declined for #{outcome.site_key}" }
      )
      puts "Login fill offered for #{outcome.site_key}"
    else
      notify(webview, outcome)
    end
  end

  # Concludes a fill from what the page reported. Public so it is testable
  # without WebKit.
  #
  # @param webview [WebKit2Gtk::WebView]
  # @param prompt [Domain::LoginFillPrompt]
  # @param report_json [String]
  # @return [void]
  def handle_report(webview, prompt, report_json)
    notice = @manager.conclude(report_json)
    if notice.nil?
      release(webview)
      puts "Login filled for #{prompt.site_key}"
    else
      notify(webview, notice)
    end
  end

  private

  # The user confirmed an account. Re-checks the live origin, fetches the
  # secret, and evaluates the fill script. The credential and the script are
  # locals; nothing here stores them.
  def confirm(webview, prompt, index)
    outcome = @manager.credential_for(prompt, index, live_origin: Domain::WebOrigin.from_url(webview.uri))

    if outcome.is_a?(Domain::LoginFillNotice)
      notify(webview, outcome)
    else
      evaluate(webview, Domain::LoginFormJs.fill_call(outcome, origin: prompt.origin)) do |json|
        handle_report(webview, prompt, json)
      end
    end
  end

  def notify(webview, notice)
    release(webview)
    @callbacks[:show_notice].call(notice)
    warn "Login fill: #{notice.reason}"
  end

  def release(webview)
    @pending.delete(webview.object_id)
  end

  # The only WebKit contact besides reading `uri`. Fire-and-forget: if the page
  # navigated the callback simply never reports, and an error releases the tab
  # so it stays usable. The script and the credential never reach a log: the
  # scripts throw nothing of their own, so an exception message here is at most
  # the page's own error, never ours.
  def evaluate(webview, script, &on_result)
    webview.evaluate_javascript(script, -1, WORLD_NAME, nil, nil) do |source, result|
      on_result.call(source.evaluate_javascript_finish(result).to_s)
    rescue StandardError => e
      warn "Login fill script failed: #{e.class}"
      release(webview)
    end
  end
end
