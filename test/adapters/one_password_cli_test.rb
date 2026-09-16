# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/adapters/one_password_cli'

class AdaptersOnePasswordCliTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'

  # Records the argv (without the timeout kwarg) and answers with a canned
  # `[stdout, stderr, status]`.
  class RecordingRunner
    Status = Struct.new(:success?)

    attr_reader :invocations

    def initialize(results = [])
      @results = results
      @invocations = []
    end

    def call(*argv, timeout:)
      @invocations << argv
      stdout, stderr, success = @results.shift || ['', '', true]
      [stdout, stderr, Status.new(success)]
    end
  end

  def cli_with(*results)
    @runner = RecordingRunner.new(results)
    Adapters::OnePasswordCli.new(runner: @runner)
  end

  def test_argv_starts_with_op_and_the_args
    cli = cli_with(['{}', '', true])

    cli.run('item', 'list', '--categories', 'Login')

    assert_equal %w[op item list --categories Login], @runner.invocations.first
  end

  def test_stdout_returned_on_success
    cli = cli_with(['{}', '', true])

    assert_equal '{}', cli.run('whoami')
  end

  def test_not_installed
    runner = ->(*_argv, **_kw) { raise Errno::ENOENT, 'op' }
    cli = Adapters::OnePasswordCli.new(runner: runner)

    assert_raises(Adapters::OnePasswordCli::NotInstalled) { cli.run('whoami') }
  end

  def test_not_signed_in_both_wordings
    ['[ERROR] You are not currently signed in. Please run op signin', 'no active session found for account cjpoll'].each do |stderr|
      cli = cli_with(['', stderr, false])

      assert_raises(Adapters::OnePasswordCli::NotSignedIn) { cli.run('item', 'list') }
    end
  end

  def test_other_failure_carries_stderr
    cli = cli_with(['', 'boom', false])

    error = assert_raises(Adapters::OnePasswordCli::Failed) { cli.run('read', 'op://x') }

    assert_equal 'boom', error.message
  end

  def test_failure_message_never_carries_stdout
    cli = cli_with([FAKE_PASSWORD, 'some error', false])

    error = assert_raises(Adapters::OnePasswordCli::Failed) { cli.run('read', 'op://x') }

    refute_includes error.message, FAKE_PASSWORD
  end

  # --- the production runner ---

  def test_the_runner_captures_both_outputs_and_the_status
    stdout, stderr, status = Adapters::OnePasswordCli::CAPTURE_RUNNER.call(
      'sh', '-c', 'echo out; echo err >&2; exit 3', timeout: 5
    )

    assert_equal "out\n", stdout
    assert_equal "err\n", stderr
    refute status.success?
  end

  def test_the_runner_gives_the_command_no_piped_input
    stdout, = Adapters::OnePasswordCli::CAPTURE_RUNNER.call('sh', '-c', 'readlink /proc/self/fd/0', timeout: 5)

    assert_equal "/dev/null\n", stdout
  end

  def test_the_runner_times_out_and_reaps_the_child
    assert_raises(Adapters::OnePasswordCli::TimedOut) do
      Adapters::OnePasswordCli::CAPTURE_RUNNER.call('sh', '-c', 'sleep 5', timeout: 0.2)
    end

    # The child was killed and reaped inside the runner, so there is no zombie
    # left for the test process to collect.
    assert_empty Process.waitall
  end

  def test_the_runner_reports_a_missing_command_as_an_error
    assert_raises(Errno::ENOENT) do
      Adapters::OnePasswordCli::CAPTURE_RUNNER.call('no-such-command-here', timeout: 5)
    end
  end
end
