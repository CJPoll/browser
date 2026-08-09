require 'minitest/autorun'
require_relative '../../lib/managers/permission_request_manager'

# Stands in for Managers::SitePermissionManager. Records what it was asked so
# the tests can assert the manager consulted the right store with the right
# key.
class MockSitePermissions
  attr_reader :media_queries, :notification_queries, :certificate_queries

  def initialize(media: {}, notifications: [], certificates: [])
    @media = media                    # host => [permission types]
    @notifications = notifications    # hosts and origins
    @certificates = certificates      # hosts
    @media_queries = []
    @notification_queries = []
    @certificate_queries = []
  end

  def media_allowed?(url, permission_type)
    @media_queries << [url, permission_type]
    host = Domain::UrlHost.host(url)
    !!host && Array(@media[host]).include?(permission_type)
  end

  def notifications_allowed?(url_or_host)
    @notification_queries << url_or_host
    host = Domain::UrlHost.host_or_bare_name(url_or_host)
    !!host && @notifications.include?(host)
  end

  def certificate_trusted?(host)
    @certificate_queries << host
    !!host && @certificates.include?(host)
  end
end

class PermissionRequestManagerTest < Minitest::Test
  def setup
    @permissions = MockSitePermissions.new(
      media: { 'meet.example.com' => [:audio_video] },
      notifications: ['chat.example.com'],
      certificates: ['self-signed.example.com']
    )
    @manager = Managers::PermissionRequestManager.new(site_permissions: @permissions)
  end

  # --- Camera and microphone ---

  def test_a_site_holding_the_media_permission_is_allowed
    decision = @manager.media_request('https://meet.example.com/room', :audio_video)

    assert_equal :allow, decision.action
    assert_equal 'meet.example.com', decision.host
  end

  def test_a_site_holding_a_different_media_permission_is_prompted_for
    decision = @manager.media_request('https://meet.example.com/room', :video)

    assert_equal :prompt, decision.action
  end

  def test_an_unknown_site_is_prompted_for_media
    decision = @manager.media_request('https://other.example.com/room', :audio)

    assert_equal :prompt, decision.action
    assert_equal 'other.example.com', decision.host
  end

  def test_a_media_request_from_a_host_less_page_is_ignored
    decision = @manager.media_request('about:blank', :audio)

    assert_equal :ignore, decision.action
  end

  def test_a_media_request_is_looked_up_by_page_url_and_type
    @manager.media_request('https://meet.example.com/room', :audio_video)

    assert_equal [['https://meet.example.com/room', :audio_video]], @permissions.media_queries
  end

  # --- Web notifications ---

  def test_a_site_allowed_to_notify_is_allowed
    decision = @manager.notification_request('https://chat.example.com/inbox')

    assert_equal :allow, decision.action
    assert_equal 'chat.example.com', decision.host
  end

  def test_an_unknown_site_is_prompted_for_notifications
    decision = @manager.notification_request('https://news.example.com/')

    assert_equal :prompt, decision.action
    assert_equal 'news.example.com', decision.host
  end

  def test_a_notification_request_from_a_host_less_page_is_ignored
    decision = @manager.notification_request(nil)

    assert_equal :ignore, decision.action
  end

  # --- Certificates ---

  def test_a_trusted_certificate_host_is_allowed
    decision = @manager.certificate_request('https://self-signed.example.com/app')

    assert_equal :allow, decision.action
    assert_equal 'self-signed.example.com', decision.host
  end

  def test_an_untrusted_certificate_host_is_prompted_for
    decision = @manager.certificate_request('https://new.example.com/app')

    assert_equal :prompt, decision.action
    assert_equal 'new.example.com', decision.host
  end

  def test_the_certificate_store_is_consulted_by_host_not_by_uri
    @manager.certificate_request('https://self-signed.example.com/app?x=1')

    assert_equal ['self-signed.example.com'], @permissions.certificate_queries
  end

  def test_an_unparseable_failing_uri_is_ignored
    decision = @manager.certificate_request('http://[bad')

    assert_equal :ignore, decision.action
  end

  # --- Permission state queries ---

  def test_a_site_allowed_to_notify_reports_granted
    assert_equal :granted, @manager.permission_state('notifications', 'chat.example.com')
  end

  def test_a_site_that_has_not_been_asked_reports_prompt
    assert_equal :prompt, @manager.permission_state('notifications', 'news.example.com')
  end

  def test_a_query_accepts_a_security_origin_as_well_as_a_host
    assert_equal :granted, @manager.permission_state('notifications', 'https://chat.example.com')
  end

  def test_a_permission_this_browser_does_not_track_is_unhandled
    assert_equal :unhandled, @manager.permission_state('geolocation', 'chat.example.com')
  end

  def test_an_unhandled_query_consults_no_store
    @manager.permission_state('geolocation', 'chat.example.com')

    assert_empty @permissions.notification_queries
  end
end
