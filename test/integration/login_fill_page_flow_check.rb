# frozen_string_literal: true

require 'minitest'
require 'json'
require 'gtk3'
require 'webkit2-gtk'
require_relative '../../lib/handlers/login_fill_handler'
require_relative '../../lib/managers/login_fill_manager'
require_relative '../../lib/domain/login_candidate'
require_relative '../../lib/domain/login_credential'

# Integration check across the page boundary: a real WebView loads a login
# page, LoginFillHandler probes it, the manager matches an in-memory login,
# and the fill script sets the fields -- firing `input` so the page's own
# listeners see the values -- WITHOUT submitting the form.
#
# Run it directly:
#
#   bundle exec ruby test/integration/login_fill_page_flow_check.rb
#
# It is not a `_test.rb` file because it cannot run under `rake test`:
# minitest/autorun runs the suite from an `at_exit` hook, and once the Ruby VM
# is exiting ruby-gnome no longer dispatches GObject signals (load-changed,
# notify::title) to Ruby handlers, although GLib timeouts still fire. Run
# through an explicit `Minitest.run` the same test passes -- see the Testing
# section of lib/ui/CLAUDE.md and test/integration/passkey_page_flow_check.rb.
class LoginFillPageFlowCheck < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  FAKE_USERNAME = 'cody@example.com'
  DEADLINE_MS = 10_000

  # Records how often it was asked to list, and reveals a fixed fake password.
  class MemoryStore
    attr_reader :list_calls, :password_calls

    def initialize(candidates)
      @candidates = candidates
      @list_calls = 0
      @password_calls = 0
    end

    def list_logins
      @list_calls += 1
      @candidates
    end

    def password_for(candidate)
      @password_calls += 1
      Domain::LoginCredential.new(username: candidate.username, password: FAKE_PASSWORD)
    end
  end

  # A login form whose script reports what was filled and refuses to submit.
  PAGE = <<~HTML.freeze
    <html><head><title>loading</title></head><body>
      <form id="f">
        <input type="text" name="username" autocomplete="username">
        <input type="password" name="password" autocomplete="current-password">
      </form>
      <script>
        var f = document.getElementById('f');
        var u = f.querySelector('input[name=username]');
        var p = f.querySelector('input[name=password]');
        var events = 0;
        function report() {
          document.title = 'done:' + JSON.stringify({ user: u.value, pass: p.value, events: events });
        }
        u.addEventListener('input', function () { events++; });
        p.addEventListener('input', function () { events++; report(); });
        f.onsubmit = function () { document.title = 'submitted'; return false; };
        document.title = 'ready';
      </script>
    </body></html>
  HTML

  # The same page without a password field: nothing to fill.
  PAGE_NO_PASSWORD = <<~HTML.freeze
    <html><head><title>loading</title></head><body>
      <form id="f"><input type="text" name="q"></form>
      <script> document.title = 'ready'; </script>
    </body></html>
  HTML

  def candidate
    Domain::LoginCandidate.new(item_id: 'i1', vault_id: 'v1', title: 'Example',
                               username: FAKE_USERNAME, urls: ['https://example.com'])
  end

  def teardown
    @webview&.destroy
  end

  # Loads a page, and once it has set up its listeners (title 'ready') triggers
  # the fill. Quits when the page reports an outcome, a notice is shown, or the
  # deadline passes. Blocks on the GTK main loop rather than sleeping.
  def run_fill(page:, base_uri:, store:)
    @notice = nil
    @prompts = []
    manager = Managers::LoginFillManager.new(store: store)
    handler = LoginFillHandler.new(
      {
        show_prompt: ->(prompt, on_fill:, **) { @prompts << prompt; on_fill.call(0) },
        show_notice: ->(notice) { @notice = notice; Gtk.main_quit }
      },
      manager: manager
    )

    @webview = WebKit2Gtk::WebView.new
    outcome = nil
    @webview.signal_connect('notify::title') do
      title = @webview.title.to_s
      if title == 'ready'
        handler.fill_current(@webview)
      elsif title.start_with?('done:', 'submitted')
        outcome = title
        Gtk.main_quit
      end
    end
    GLib::Timeout.add(DEADLINE_MS) { Gtk.main_quit; false }
    @webview.load_html(page, base_uri)
    Gtk.main
    outcome
  end

  def test_fills_both_fields_without_submitting
    store = MemoryStore.new([candidate])

    outcome = run_fill(page: PAGE, base_uri: 'https://accounts.example.com/', store: store)

    refute_nil outcome, 'the page never reported back'
    refute_equal 'submitted', outcome, 'the form must never be submitted'
    assert outcome.start_with?('done:'), outcome
    report = JSON.parse(outcome.delete_prefix('done:'))

    assert_equal FAKE_USERNAME, report['user']
    assert_equal FAKE_PASSWORD, report['pass']
    assert_operator report['events'], :>=, 2
    assert_equal 1, @prompts.length
    assert_equal 'example.com', @prompts.first.site_key
  end

  def test_a_page_with_no_password_field_ends_in_a_notice_and_lists_nothing
    store = MemoryStore.new([candidate])

    run_fill(page: PAGE_NO_PASSWORD, base_uri: 'https://accounts.example.com/', store: store)

    refute_nil @notice, 'a notice should have been shown'
    assert_equal :no_login_form, @notice.reason
    assert_equal 0, store.list_calls, 'the store must not be consulted with no form'
  end

  def test_an_insecure_origin_is_refused
    store = MemoryStore.new([candidate])

    run_fill(page: PAGE, base_uri: 'http://insecure.example/', store: store)

    refute_nil @notice, 'a notice should have been shown'
    assert_equal :insecure_origin, @notice.reason
    assert_equal 0, store.list_calls
  end
end

exit Minitest.run(ARGV) if __FILE__ == $PROGRAM_NAME
