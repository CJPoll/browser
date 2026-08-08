require 'minitest/autorun'
require_relative '../../lib/adapters/system_notifier'

class AdaptersSystemNotifierTest < Minitest::Test
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
    @notifier = Adapters::SystemNotifier.new(runner: @runner)
  end

  def argv
    @runner.invocations.first
  end

  def test_sends_the_title_and_body_to_notify_send
    @notifier.notify(title: 'Build finished', body: 'All tests passed')

    assert_equal 'notify-send', argv.first
    assert_equal ['Build finished', 'All tests passed'], argv.last(2)
  end

  def test_identifies_the_notifying_site_as_the_application
    @notifier.notify(title: 'Hi', body: '', app_name: 'news.example')

    assert_includes argv, '--app-name=news.example'
  end

  def test_omits_the_application_name_when_there_is_none
    @notifier.notify(title: 'Hi', body: '')

    refute(argv.any? { |arg| arg.start_with?('--app-name=') })
  end

  def test_uses_the_browser_icon_by_default
    @notifier.notify(title: 'Hi', body: '')

    assert_includes argv, '--icon=web-browser'
  end

  def test_allows_a_different_icon
    @notifier.notify(title: 'Hi', body: '', icon: 'dialog-information')

    assert_includes argv, '--icon=dialog-information'
  end

  def test_omits_the_icon_when_it_is_suppressed
    @notifier.notify(title: 'Hi', body: '', icon: nil)

    refute(argv.any? { |arg| arg.start_with?('--icon=') })
  end

  def test_sends_an_empty_body_when_none_is_given
    @notifier.notify(title: 'Hi')

    assert_equal ['Hi', ''], argv.last(2)
  end

  # Arguments are passed separately, so notification text from a web page is
  # data rather than something the shell can act on.
  def test_passes_notification_text_as_separate_arguments
    @notifier.notify(title: '$(whoami)', body: '`id`')

    assert_equal ['$(whoami)', '`id`'], argv.last(2)
  end

  # Known wart, preserved from the call site this adapter replaced: the title
  # is not separated from the options by "--", so a title that looks like a
  # flag is handed to notify-send as one.
  def test_does_not_shield_a_flag_like_title_from_notify_send
    @notifier.notify(title: '--help', body: '')

    assert_equal ['--help', ''], argv.last(2)
    refute_includes argv, '--'
  end

  def test_reports_success
    assert_equal true, @notifier.notify(title: 'Hi')
  end

  def test_reports_failure_when_notify_send_is_missing
    notifier = Adapters::SystemNotifier.new(runner: RecordingRunner.new(result: nil))

    assert_equal false, notifier.notify(title: 'Hi')
  end
end
