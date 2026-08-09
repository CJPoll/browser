require 'minitest/autorun'
require_relative '../../lib/domain/web_notification'

class WebNotificationTest < Minitest::Test
  def test_carries_the_title_body_and_sending_host
    notification = Domain::WebNotification.for(
      title: 'Build finished',
      body: 'main is green',
      page_url: 'https://ci.example.com/builds/7'
    )

    assert_equal 'Build finished', notification.title
    assert_equal 'main is green', notification.body
    assert_equal 'ci.example.com', notification.host
  end

  def test_a_notification_without_a_title_is_named_generically
    notification = Domain::WebNotification.for(title: nil, body: 'body', page_url: 'https://example.com')

    assert_equal 'Web Notification', notification.title
  end

  def test_a_notification_without_a_body_shows_an_empty_one
    notification = Domain::WebNotification.for(title: 'Title', body: nil, page_url: 'https://example.com')

    assert_equal '', notification.body
  end

  def test_an_empty_title_is_kept_rather_than_replaced
    notification = Domain::WebNotification.for(title: '', body: 'body', page_url: 'https://example.com')

    assert_equal '', notification.title
  end

  def test_a_page_with_no_identifiable_host_sends_as_unknown
    notification = Domain::WebNotification.for(title: 'Title', body: '', page_url: 'about:blank')

    assert_equal 'unknown', notification.host
  end

  def test_a_missing_page_url_sends_as_unknown
    notification = Domain::WebNotification.for(title: 'Title', body: '', page_url: nil)

    assert_equal 'unknown', notification.host
  end

  def test_a_malformed_page_url_sends_as_unknown
    notification = Domain::WebNotification.for(title: 'Title', body: '', page_url: 'http://[bad')

    assert_equal 'unknown', notification.host
  end

  # --- Value semantics ---

  def test_notifications_with_the_same_attributes_are_equal
    first = Domain::WebNotification.for(title: 'T', body: 'B', page_url: 'https://example.com')
    second = Domain::WebNotification.for(title: 'T', body: 'B', page_url: 'https://example.com')

    assert_equal first, second
    assert_equal first.hash, second.hash
  end

  def test_a_notification_is_not_equal_to_a_lookalike_hash
    notification = Domain::WebNotification.for(title: 'T', body: 'B', page_url: 'https://example.com')

    refute_equal notification, notification.to_h
  end

  def test_to_h_exposes_every_attribute
    notification = Domain::WebNotification.for(title: 'T', body: 'B', page_url: 'https://example.com')

    assert_equal({ title: 'T', body: 'B', host: 'example.com' }, notification.to_h)
  end

  def test_title_is_required_when_constructed_directly
    error = assert_raises(ArgumentError) { Domain::WebNotification.new(title: nil, body: '', host: 'example.com') }

    assert_match(/title/, error.message)
  end
end
