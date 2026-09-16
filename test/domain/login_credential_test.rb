# frozen_string_literal: true

require 'minitest/autorun'
require 'pp'
require_relative '../../lib/domain/login_credential'

class DomainLoginCredentialTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'
  FAKE_USERNAME = 'cody@example.com'
  REDACTED = '#<Domain::LoginCredential (redacted)>'

  def build(username: FAKE_USERNAME, password: FAKE_PASSWORD)
    Domain::LoginCredential.new(username: username, password: password)
  end

  def test_requires_a_non_empty_password
    assert_raises(ArgumentError) { build(password: nil) }
    assert_raises(ArgumentError) { build(password: '') }
  end

  def test_username_may_be_nil
    assert_nil build(username: nil).username
  end

  def test_inspect_redacts
    credential = build

    assert_equal REDACTED, credential.inspect
    refute_includes credential.inspect, FAKE_PASSWORD
    refute_includes credential.inspect, FAKE_USERNAME
  end

  def test_to_s_and_interpolation_redact
    credential = build

    assert_equal REDACTED, credential.to_s
    assert_equal REDACTED, "#{credential}"
    refute_includes "#{credential}", FAKE_PASSWORD
  end

  def test_pp_redacts
    out, = capture_io { pp build }

    assert_includes out, REDACTED
    refute_includes out, FAKE_PASSWORD
  end

  def test_to_h_redacts
    hash = build.to_h

    assert_equal '[REDACTED]', hash[:password]
    assert_equal FAKE_USERNAME, hash[:username]
    refute_includes hash.inspect, FAKE_PASSWORD
  end

  def test_equality_by_value
    assert_equal build, build
    refute_equal build, build(password: 'different')
    refute_equal build, Object.new
  end

  def test_frozen
    assert_predicate build, :frozen?
  end

  def test_readers_still_expose_the_real_values
    credential = build

    assert_equal FAKE_PASSWORD, credential.password
    assert_equal FAKE_USERNAME, credential.username
  end
end
