# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/domain/login_fill_notice'

class DomainLoginFillNoticeTest < Minitest::Test
  def notice(reason, detail: nil)
    Domain::LoginFillNotice.new(reason: reason, detail: detail)
  end

  def test_fixed_reason_messages
    {
      no_origin: 'Login fill needs an http(s) page to match against',
      insecure_origin: 'Login fill is only offered on https pages (or localhost)',
      no_login_form: 'No password field was found on this page',
      not_installed: 'The 1Password CLI (op) is not installed',
      not_signed_in: '1Password is locked: run op signin in a terminal, then try again',
      timed_out: '1Password did not answer in time',
      origin_changed: 'The page changed before the login was filled; nothing was filled'
    }.each do |reason, message|
      assert_equal message, notice(reason).message
    end
  end

  def test_no_matches_includes_the_site_key
    assert_equal 'No 1Password login matches google.com', notice(:no_matches, detail: 'google.com').message
  end

  def test_unavailable_includes_the_detail
    assert_equal '1Password is unavailable: boom', notice(:unavailable, detail: 'boom').message
  end

  def test_fill_failed_includes_the_detail
    assert_equal 'The login could not be filled (no_password_field)', notice(:fill_failed, detail: 'no_password_field').message
  end

  def test_unknown_reason_raises
    assert_raises(ArgumentError) { notice(:nope) }
  end

  def test_equality
    assert_equal notice(:no_login_form), notice(:no_login_form)
    refute_equal notice(:no_matches, detail: 'a'), notice(:no_matches, detail: 'b')
  end
end
