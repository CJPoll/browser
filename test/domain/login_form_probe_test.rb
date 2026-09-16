# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/login_form_probe'

class DomainLoginFormProbeTest < Minitest::Test
  def test_well_formed
    probe = Domain::LoginFormProbe.parse(JSON.generate(top: true, origin: 'https://x.example', password: true, username: true))

    assert probe.top?
    assert_equal 'https://x.example', probe.origin
    assert probe.password_field?
    assert probe.username_field?
  end

  def test_missing_keys_default_false
    probe = Domain::LoginFormProbe.parse('{}')

    refute probe.top?
    assert_nil probe.origin
    refute probe.password_field?
    refute probe.username_field?
  end

  def test_password_false_when_absent
    probe = Domain::LoginFormProbe.parse(JSON.generate(top: true, password: false))

    refute probe.password_field?
  end

  def test_non_json_is_safe
    ['not json', '', nil].each do |input|
      probe = Domain::LoginFormProbe.parse(input)

      refute probe.password_field?
      refute probe.top?
    end
  end

  def test_json_that_is_not_an_object_is_safe
    ['[]', '"x"', '42'].each do |input|
      probe = Domain::LoginFormProbe.parse(input)

      refute probe.password_field?
    end
  end
end
