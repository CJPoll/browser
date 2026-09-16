# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/login_form_js'
require_relative '../../lib/domain/login_credential'

class DomainLoginFormJsTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  FAKE_USERNAME = 'cody@example.com'
  ORIGIN = 'https://accounts.example.com'

  NO_SUBMIT = /submit|requestSubmit|\.click\(|KeyboardEvent|Enter/i
  # A real global assignment (`window.foo =`), NOT a comparison
  # (`window.top === window`), which the plain `window\.\w+ *=` form would
  # false-positive on. See the deviation note in the mission report.
  GLOBAL_ASSIGNMENT = /window\.[a-zA-Z_]+\s*=(?!=)/

  def credential(username: FAKE_USERNAME, password: FAKE_PASSWORD)
    Domain::LoginCredential.new(username: username, password: password)
  end

  def argument_of(fill_call)
    fill_call.delete_prefix("#{Domain::LoginFormJs::FILL}(").delete_suffix(');')
  end

  def test_probe_is_an_iife_returning_json
    probe = Domain::LoginFormJs.probe_script

    assert probe.start_with?('(function'), probe[0, 20]
    assert_includes probe, 'JSON.stringify'
    assert_includes probe, 'passwordField()'
  end

  def test_both_scripts_share_the_field_finder
    assert_includes Domain::LoginFormJs::PROBE, Domain::LoginFormJs::FIELD_FINDER
    assert_includes Domain::LoginFormJs::FILL, Domain::LoginFormJs::FIELD_FINDER
  end

  def test_never_submits
    refute_match NO_SUBMIT, Domain::LoginFormJs::PROBE
    refute_match NO_SUBMIT, Domain::LoginFormJs::FILL
  end

  def test_creates_no_globals
    [Domain::LoginFormJs::PROBE, Domain::LoginFormJs::FILL].each do |script|
      refute_match(/window\.__/, script)
      refute_match(GLOBAL_ASSIGNMENT, script)
    end
  end

  def test_fill_guards_top_document_and_origin
    assert_includes Domain::LoginFormJs::FILL, 'window.top !== window'
    assert_includes Domain::LoginFormJs::FILL, 'window.location.origin !== fill.origin'
  end

  def test_fill_call_embeds_the_credential_as_a_json_argument
    parsed = JSON.parse(argument_of(Domain::LoginFormJs.fill_call(credential, origin: ORIGIN)))

    assert_equal FAKE_USERNAME, parsed['username']
    assert_equal FAKE_PASSWORD, parsed['password']
    assert_equal ORIGIN, parsed['origin']
  end

  def test_fill_call_escapes_hostile_values
    hostile = %(</script>'" )
    call = Domain::LoginFormJs.fill_call(credential(password: hostile), origin: ORIGIN)

    refute_includes call, " "
    assert_equal hostile, JSON.parse(argument_of(call))['password']
  end

  def test_nil_username_passes_as_null
    call = Domain::LoginFormJs.fill_call(credential(username: nil), origin: ORIGIN)

    assert_nil JSON.parse(argument_of(call))['username']
    assert_includes call, '"username":null'
  end

  def test_world_name
    assert_equal 'toy-browser-login-fill', Domain::LoginFormJs::WORLD_NAME
  end

  def test_fill_call_ends_in_a_single_statement
    call = Domain::LoginFormJs.fill_call(credential, origin: ORIGIN)

    assert call.rstrip.end_with?(');'), call[-10..]
  end
end
