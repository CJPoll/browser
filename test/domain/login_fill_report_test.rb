# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/domain/login_fill_report'

class DomainLoginFillReportTest < Minitest::Test
  def test_filled_report
    report = Domain::LoginFillReport.parse(JSON.generate(ok: true, username: true, password: true))

    assert report.filled?
    assert report.username_filled?
    assert_nil report.reason
  end

  def test_password_only
    report = Domain::LoginFillReport.parse(JSON.generate(ok: true, username: false, password: true))

    assert report.filled?
    refute report.username_filled?
  end

  def test_failed_report_carries_the_reason_symbol
    report = Domain::LoginFillReport.parse(JSON.generate(ok: false, reason: 'no_password_field'))

    refute report.filled?
    assert_equal :no_password_field, report.reason
  end

  def test_non_json_is_unreadable
    ['x', '', nil].each do |input|
      report = Domain::LoginFillReport.parse(input)

      refute report.filled?
      assert_equal :unreadable_report, report.reason
    end
  end

  def test_json_that_is_not_an_object_is_unreadable
    report = Domain::LoginFillReport.parse('[]')

    refute report.filled?
    assert_equal :unreadable_report, report.reason
  end
end
