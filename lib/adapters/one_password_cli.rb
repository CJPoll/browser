# frozen_string_literal: true

require 'timeout'

module Adapters
  # One invocation of the `op` command-line tool: argv (never a shell string),
  # no stdin, a hard timeout, and an error taxonomy the manager can map to
  # user-facing notices.
  #
  # Follows lib/adapters/CLAUDE.md ("shelling out for an answer: capture, do
  # not just run"): the runner answers `[stdout, stderr, status]` and is
  # injected so tests never touch the real `op`.
  #
  # stdout is never put into any error message: for `op read` it is the
  # password, and `run` (the launcher) tees stderr to disk.
  class OnePasswordCli
    class Error < StandardError; end
    # `op` is not on PATH.
    class NotInstalled < Error; end
    # `op` has no active session (the vault is locked).
    class NotSignedIn < Error; end
    # `op` did not answer within the timeout (e.g. an unanswered desktop-app
    # auth dialog) and was killed.
    class TimedOut < Error; end
    # Any other non-zero exit; the message is stderr, stripped.
    class Failed < Error; end

    COMMAND = 'op'
    TIMEOUT_SECONDS = 30
    NOT_SIGNED_IN = /not currently signed in|no active session/i

    # Spawns argv with stdin on /dev/null (so `op` never reads a pipe as a
    # JSON template and never blocks on a TTY prompt), captures both outputs on
    # reader threads, and enforces a hard timeout: on expiry the child is
    # KILLed and reaped so it can never hang the browser.
    #
    # @return [Array(String, String, Process::Status)]
    # @raise [TimedOut]
    CAPTURE_RUNNER = lambda do |*argv, timeout:|
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      pid = Process.spawn(*argv, in: File::NULL, out: stdout_writer, err: stderr_writer)
      stdout_writer.close
      stderr_writer.close
      stdout_thread = Thread.new { stdout_reader.read }
      stderr_thread = Thread.new { stderr_reader.read }
      begin
        _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
      rescue Timeout::Error
        Process.kill('KILL', pid)
        Process.wait(pid)
        stdout_thread.join
        stderr_thread.join
        raise TimedOut, 'op did not answer in time'
      end
      [stdout_thread.value, stderr_thread.value, status]
    ensure
      [stdout_reader, stderr_reader].each { |io| io&.close }
    end

    # @param runner [#call] receives `(*argv, timeout:)`, answers
    #   `[stdout, stderr, status]`
    # @param timeout [Numeric] seconds
    def initialize(runner: CAPTURE_RUNNER, timeout: TIMEOUT_SECONDS)
      @runner = runner
      @timeout = timeout
    end

    # @param args [Array<String>] the `op` arguments (without the command)
    # @return [String] stdout on success
    # @raise [NotInstalled, NotSignedIn, TimedOut, Failed]
    def run(*args)
      stdout, stderr, status = @runner.call(COMMAND, *args, timeout: @timeout)
      return stdout if status.success?

      raise NotSignedIn, stderr.to_s.strip if NOT_SIGNED_IN.match?(stderr.to_s)

      raise Failed, stderr.to_s.strip
    rescue Errno::ENOENT
      raise NotInstalled, "#{COMMAND} is not installed"
    end
  end
end
