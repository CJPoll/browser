require 'minitest/autorun'
require_relative '../../lib/managers/web_notification_dispatcher'

# Stands in for Adapters::SystemNotifier -- records instead of shelling out.
class MockSystemNotifier
  attr_reader :notifications

  def initialize(result: true)
    @notifications = []
    @result = result
  end

  def notify(title:, body: '', app_name: nil)
    @notifications << { title: title, body: body, app_name: app_name }
    @result
  end
end

class WebNotificationDispatcherTest < Minitest::Test
  def setup
    @notifier = MockSystemNotifier.new
    @dispatcher = Managers::WebNotificationDispatcher.new(notifier: @notifier)
  end

  def test_hands_the_notification_to_the_desktop
    @dispatcher.dispatch(title: 'Build finished', body: 'main is green', page_url: 'https://ci.example.com/7')

    assert_equal(
      [{ title: 'Build finished', body: 'main is green', app_name: 'ci.example.com' }],
      @notifier.notifications
    )
  end

  def test_attributes_the_notification_to_the_sending_host
    @dispatcher.dispatch(title: 'Hi', body: '', page_url: 'https://chat.example.com/room/1')

    assert_equal 'chat.example.com', @notifier.notifications.first[:app_name]
  end

  def test_a_page_with_no_host_is_attributed_to_unknown
    @dispatcher.dispatch(title: 'Hi', body: '', page_url: 'about:blank')

    assert_equal 'unknown', @notifier.notifications.first[:app_name]
  end

  def test_a_notification_missing_its_title_and_body_is_still_shown
    @dispatcher.dispatch(title: nil, body: nil, page_url: 'https://example.com')

    assert_equal(
      [{ title: 'Web Notification', body: '', app_name: 'example.com' }],
      @notifier.notifications
    )
  end

  def test_returns_what_was_shown_so_the_caller_can_report_it
    shown = @dispatcher.dispatch(title: 'Hi', body: 'there', page_url: 'https://example.com')

    assert_equal 'Hi', shown.title
    assert_equal 'example.com', shown.host
  end
end
