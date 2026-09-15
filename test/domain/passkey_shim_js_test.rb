require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/passkey_shim_js'
require_relative '../../lib/domain/passkey_response'

class PasskeyShimJsTest < Minitest::Test
  def script
    Domain::PasskeyShimJs.script
  end

  def test_names_the_message_handler_the_framework_registers
    assert_equal 'passkey', Domain::PasskeyShimJs::HANDLER_NAME
    assert_includes script, "var HANDLER = 'passkey';"
    assert_includes script, 'messageHandlers[HANDLER].postMessage'
  end

  def test_defines_the_credentials_container
    assert_includes script, "Object.defineProperty(navigator, 'credentials'"
    assert_includes script, "request('create'"
    assert_includes script, "request('get'"
  end

  def test_defines_the_public_key_credential_global
    assert_includes script, 'window.PublicKeyCredential = PublicKeyCredential'
    assert_includes script, 'isUserVerifyingPlatformAuthenticatorAvailable'
    assert_includes script, 'isConditionalMediationAvailable'
  end

  def test_answers_the_client_capabilities_query_as_a_platform_authenticator
    assert_includes script, 'PublicKeyCredential.getClientCapabilities = function ()'
    assert_includes script, 'passkeyPlatformAuthenticator: true'
    assert_includes script, 'conditionalGet: false'
  end

  def test_exposes_the_completion_entry_point_the_framework_calls
    assert_includes script, 'window.__toyPasskey = {'
    assert_includes script, 'complete: function (result)'
  end

  def test_installs_itself_only_once
    assert_includes script, 'if (window.__toyPasskey) { return; }'
  end

  def test_the_same_call_returns_the_same_script
    assert_equal script, Domain::PasskeyShimJs.script
  end

  # --- completion_call ---

  def test_completion_call_hands_the_response_to_the_page
    response = Domain::PasskeyResponse.rejected(request_id: 'passkey-1', name: 'NotAllowedError', message: 'declined')

    assert_equal "window.__toyPasskey.complete(#{response.to_json});", Domain::PasskeyShimJs.completion_call(response)
  end

  def test_completion_call_escapes_line_separators_that_break_javascript
    # U+2028 is legal in JSON but ends a JavaScript statement.
    response = Domain::PasskeyResponse.rejected(request_id: 'passkey-1', name: 'NotAllowedError', message: "a b")

    call = Domain::PasskeyShimJs.completion_call(response)

    refute_includes call, " "
    assert_includes call, '\\u2028'
  end
end
