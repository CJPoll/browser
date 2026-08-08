require 'minitest/autorun'
require_relative '../../lib/adapters/uri_opener'

class AdaptersUriOpenerTest < Minitest::Test
  # Records what would have been run instead of running it.
  class RecordingRunner
    attr_reader :invocations

    def initialize(result: true)
      @invocations = []
      @result = result
    end

    def call(*argv)
      @invocations << argv
      @result
    end
  end

  def setup
    @runner = RecordingRunner.new
    @opener = Adapters::UriOpener.new(runner: @runner)
  end

  def test_hands_the_uri_to_xdg_open
    @opener.open('https://example.com')

    assert_equal [['xdg-open', 'https://example.com']], @runner.invocations
  end

  def test_opens_local_paths_too
    @opener.open('/home/user/Downloads/report.pdf')

    assert_equal [['xdg-open', '/home/user/Downloads/report.pdf']], @runner.invocations
  end

  # Each argument is passed separately, so a target containing shell
  # metacharacters is data rather than something to execute.
  def test_passes_the_target_as_a_separate_argument
    @opener.open('https://example.com/a; rm -rf ~')

    assert_equal ['xdg-open', 'https://example.com/a; rm -rf ~'], @runner.invocations.first
  end

  def test_reports_success
    assert_equal true, @opener.open('https://example.com')
  end

  def test_reports_failure_when_the_command_could_not_be_run
    opener = Adapters::UriOpener.new(runner: RecordingRunner.new(result: nil))

    assert_equal false, opener.open('https://example.com')
  end

  def test_does_not_run_anything_for_a_nil_target
    assert_equal false, @opener.open(nil)
    assert_empty @runner.invocations
  end

  def test_does_not_run_anything_for_a_blank_target
    assert_equal false, @opener.open('   ')
    assert_empty @runner.invocations
  end
end
