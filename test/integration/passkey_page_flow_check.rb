require 'minitest'
require 'json'
require 'gtk3'
require 'webkit2-gtk'
require_relative '../../lib/handlers/passkey_handler'
require_relative '../../lib/managers/passkey_manager'
require_relative '../../lib/adapters/es256_signer'
require_relative '../../lib/domain/base64url'
require_relative '../support/test_clock'

# Integration check across the page boundary: a real WebView runs the injected
# shim, the shim's message reaches PasskeyHandler, the manager registers a key
# with the real signer, and the page's promise resolves with a
# PublicKeyCredential it can serialise.
#
# Run it directly:
#
#   bundle exec ruby test/integration/passkey_page_flow_check.rb
#
# It is not a `_test.rb` file because it cannot run under `rake test`:
# minitest/autorun runs the suite from an `at_exit` hook, and once the Ruby VM
# is exiting ruby-gnome no longer dispatches GObject signals (load-changed,
# script-message-received, notify::title) to Ruby handlers, although GLib
# timeouts still fire. Run through an explicit `Minitest.run` the same test
# passes -- see the Testing section of lib/ui/CLAUDE.md.
#
# The consent bar is played by a callback that answers at once; the store is
# in memory. Everything else is the production path.
class PasskeyPageFlowCheck < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze
  DEADLINE_MS = 10_000

  class MemoryStore
    def initialize = @passkeys = []
    def save(passkey) = (@passkeys << passkey.with(store_id: 'item-1')).last
    def find_for_rp(rp_id) = @passkeys.select { |passkey| passkey.rp_id == rp_id }
  end

  PAGE = <<~HTML.freeze
    <html><head><title>waiting</title></head><body><script>
      var challenge = new Uint8Array([1, 2, 3, 4]).buffer;
      var user = { id: new Uint8Array([9, 9]).buffer, name: 'cody@example.com', displayName: 'Cody' };
      navigator.credentials.create({ publicKey: {
        rp: { id: 'example.com', name: 'Example' }, user: user, challenge: challenge,
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }]
      } }).then(function (credential) {
        // A document title is capped at about a thousand characters, so
        // report sizes rather than the attestation bytes themselves.
        var json = credential.toJSON();
        var report = {
          id: credential.id, type: credential.type, authenticatorAttachment: credential.authenticatorAttachment,
          isPublicKeyCredential: credential instanceof PublicKeyCredential,
          rawIdBytes: new Uint8Array(credential.rawId).length,
          attestationBytes: new Uint8Array(credential.response.attestationObject).length,
          transports: credential.response.getTransports(),
          publicKeyAlgorithm: credential.response.getPublicKeyAlgorithm(),
          clientDataJSON: json.response.clientDataJSON
        };
        document.title = 'done:' + JSON.stringify(report);
      }).catch(function (error) {
        document.title = 'error:' + error.name + ':' + error.message;
      });
    </script></body></html>
  HTML

  def setup
    @manager = Managers::PasskeyManager.new(store: MemoryStore.new, signer: Adapters::Es256Signer.new, clock: TestClock.new(NOW))
    @prompts = []
  end

  def teardown
    @webview&.destroy
  end

  # Runs the page until its title reports an outcome, or the deadline passes.
  # This blocks on the GTK main loop rather than sleeping and re-checking.
  def run_page(handler)
    @webview = WebKit2Gtk::WebView.new(user_content_manager: WebKit2Gtk::UserContentManager.new)
    handler.attach(@webview)
    outcome = nil
    @webview.signal_connect('notify::title') do
      title = @webview.title.to_s
      next unless title.start_with?('done:', 'error:')

      outcome = title
      Gtk.main_quit
    end
    GLib::Timeout.add(DEADLINE_MS) { Gtk.main_quit; false }
    @webview.load_html(PAGE, 'https://accounts.example.com/')
    Gtk.main
    outcome
  end

  def test_a_page_registers_a_passkey_through_the_shim
    handler = PasskeyHandler.new(
      { show_prompt: ->(prompt, on_allow:, **) { @prompts << prompt; on_allow.call(0) } },
      manager: @manager
    )

    outcome = run_page(handler)

    refute_nil outcome, 'the page never reported back'
    assert outcome.start_with?('done:'), outcome
    report = JSON.parse(outcome.delete_prefix('done:'))

    assert_equal 1, @prompts.length
    assert_equal 'example.com', @prompts.first.rp_id
    assert_equal 'https://accounts.example.com', @prompts.first.origin

    assert report['isPublicKeyCredential']
    assert_equal 'public-key', report['type']
    assert_equal 'platform', report['authenticatorAttachment']
    assert_equal 32, report['rawIdBytes']
    assert_equal ['internal'], report['transports']
    assert_equal(-7, report['publicKeyAlgorithm'])
    assert_operator report['attestationBytes'], :>, 100
    client_data = JSON.parse(Domain::Base64Url.decode(report['clientDataJSON']))
    assert_equal 'webauthn.create', client_data['type']
    assert_equal 'AQIDBA', client_data['challenge']
    assert_equal 'https://accounts.example.com', client_data['origin']
  end

  def test_a_declined_request_rejects_the_page_promise_with_not_allowed
    handler = PasskeyHandler.new(
      { show_prompt: ->(_prompt, on_cancel:, **) { on_cancel.call } },
      manager: @manager
    )

    outcome = run_page(handler)

    assert_equal 'error:NotAllowedError:The user declined', outcome
  end
end

exit Minitest.run(ARGV) if __FILE__ == $PROGRAM_NAME
