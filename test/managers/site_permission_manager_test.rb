require 'minitest/autorun'
require_relative '../../lib/managers/site_permission_manager'

# Stands in for the three host-keyed permission repositories.
class MockHostPermissionRepository
  attr_reader :added, :removed

  def initialize
    @permissions = {}
    @added = []
    @removed = []
    @next_id = 1
  end

  def exists?(host)
    return false unless host

    @permissions.key?(host)
  end

  def add(permission)
    @added << permission
    return nil if @permissions.key?(permission.host)

    stored = permission.with_id(@next_id)
    @next_id += 1
    @permissions[permission.host] = stored
    stored
  end

  def remove(host)
    @removed << host
    return false unless host

    !@permissions.delete(host).nil?
  end

  def all
    @permissions.values.sort_by(&:host)
  end
end

# The media store is keyed on (host, type), so it needs its own stand-in.
class MockMediaPermissionRepository
  attr_reader :added, :removed

  def initialize
    @permissions = {}
    @added = []
    @removed = []
    @next_id = 1
  end

  def exists?(host, permission_type)
    return false unless host && permission_type

    @permissions.key?([host, permission_type.to_sym])
  end

  def add(permission)
    @added << permission
    key = [permission.host, permission.permission_type]
    return nil if @permissions.key?(key)

    stored = permission.with_id(@next_id)
    @next_id += 1
    @permissions[key] = stored
    stored
  end

  def remove(host, permission_type = nil)
    @removed << [host, permission_type]
    return false unless host

    matching = @permissions.keys.select do |stored_host, stored_type|
      stored_host == host && (permission_type.nil? || stored_type == permission_type.to_sym)
    end
    matching.each { |key| @permissions.delete(key) }
    matching.any?
  end

  def all
    @permissions.values.sort_by(&:host)
  end
end

class TestClock
  def initialize(time)
    @time = time
  end

  def call
    @time
  end

  def advance(seconds)
    @time += seconds
    self
  end
end

class SitePermissionManagerTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @popups = MockHostPermissionRepository.new
    @media = MockMediaPermissionRepository.new
    @notifications = MockHostPermissionRepository.new
    @certificates = MockHostPermissionRepository.new
    @clock = TestClock.new(NOW)

    @manager = Managers::SitePermissionManager.new(
      popup_repository: @popups,
      media_repository: @media,
      notification_repository: @notifications,
      certificate_repository: @certificates,
      clock: @clock
    )
  end

  # --- Popups ---

  def test_allow_popups_stores_the_url_host
    permission = @manager.allow_popups('https://example.com/some/page?a=1')

    assert_equal 'example.com', permission.host
    assert @manager.popups_allowed?('https://example.com/other')
  end

  def test_allow_popups_stamps_the_injected_time
    @clock.advance(90)

    assert_equal NOW + 90, @manager.allow_popups('https://example.com').granted_at
  end

  def test_allow_popups_returns_nil_when_the_host_is_already_allowed
    @manager.allow_popups('https://example.com')

    assert_nil @manager.allow_popups('https://example.com')
  end

  def test_popups_are_blocked_until_allowed
    refute @manager.popups_allowed?('https://example.com')
  end

  def test_popup_permission_is_host_specific
    @manager.allow_popups('https://example.com')

    refute @manager.popups_allowed?('https://other.com')
  end

  def test_popups_are_blocked_for_a_url_with_no_host
    refute @manager.popups_allowed?('not a url')
    refute @manager.popups_allowed?(nil)
  end

  def test_allow_popups_does_nothing_for_a_url_with_no_host
    assert_nil @manager.allow_popups('not a url')
    assert_empty @popups.added
  end

  def test_revoke_popup_permission_takes_a_host
    @manager.allow_popups('https://example.com')

    assert @manager.revoke_popup_permission('example.com')
    refute @manager.popups_allowed?('https://example.com')
  end

  def test_revoke_popup_permission_reports_false_when_nothing_was_stored
    refute @manager.revoke_popup_permission('example.com')
  end

  def test_popup_permissions_lists_what_is_stored
    @manager.allow_popups('https://zebra.com')
    @manager.allow_popups('https://apple.com')

    assert_equal %w[apple.com zebra.com], @manager.popup_permissions.map(&:host)
  end

  # --- Media ---

  def test_allow_media_stores_the_host_and_type
    permission = @manager.allow_media('https://meet.example.com/room', :audio_video)

    assert_equal 'meet.example.com', permission.host
    assert_equal :audio_video, permission.permission_type
    assert_equal NOW, permission.granted_at
  end

  def test_media_permission_is_specific_to_the_type
    @manager.allow_media('https://meet.example.com', :audio)

    assert @manager.media_allowed?('https://meet.example.com', :audio)
    refute @manager.media_allowed?('https://meet.example.com', :video)
  end

  def test_media_is_denied_for_a_url_with_no_host
    refute @manager.media_allowed?('not a url', :audio)
    assert_nil @manager.allow_media('not a url', :audio)
  end

  def test_media_is_denied_for_an_unknown_permission_type
    refute @manager.media_allowed?('https://meet.example.com', :location)
  end

  # A type this browser cannot grant must not reach the store, where it would
  # linger as an unrevokable row.
  def test_allow_media_refuses_an_unknown_permission_type
    assert_nil @manager.allow_media('https://meet.example.com', :location)
    assert_empty @media.added
  end

  def test_revoke_media_permission_takes_a_host_and_type
    @manager.allow_media('https://meet.example.com', :audio)
    @manager.allow_media('https://meet.example.com', :video)

    assert @manager.revoke_media_permission('meet.example.com', :audio)

    refute @manager.media_allowed?('https://meet.example.com', :audio)
    assert @manager.media_allowed?('https://meet.example.com', :video)
  end

  def test_revoke_media_permission_without_a_type_revokes_every_type
    @manager.allow_media('https://meet.example.com', :audio)
    @manager.allow_media('https://meet.example.com', :video)

    assert @manager.revoke_media_permission('meet.example.com')

    assert_empty @manager.media_permissions
  end

  def test_media_permissions_lists_what_is_stored
    @manager.allow_media('https://meet.example.com', :audio)

    permission = @manager.media_permissions.first

    assert_equal 'meet.example.com', permission.host
    assert_equal :audio, permission.permission_type
  end

  # --- Notifications ---

  def test_allow_notifications_stores_the_url_host
    permission = @manager.allow_notifications('https://claude.ai/chat')

    assert_equal 'claude.ai', permission.host
    assert @manager.notifications_allowed?('https://claude.ai/other')
  end

  # WebKit's permission-state query hands over a security origin, and the
  # permissions window revokes by host, so both forms have to resolve.
  def test_notifications_allowed_accepts_a_bare_host
    @manager.allow_notifications('https://claude.ai')

    assert @manager.notifications_allowed?('claude.ai')
  end

  def test_notifications_are_blocked_until_allowed
    refute @manager.notifications_allowed?('https://claude.ai')
  end

  def test_notifications_are_blocked_for_a_url_with_no_host
    refute @manager.notifications_allowed?(nil)
    assert_nil @manager.allow_notifications(nil)
  end

  def test_revoke_notification_permission_takes_a_host
    @manager.allow_notifications('https://claude.ai')

    assert @manager.revoke_notification_permission('claude.ai')
    refute @manager.notifications_allowed?('https://claude.ai')
  end

  def test_notification_permissions_lists_what_is_stored
    @manager.allow_notifications('https://claude.ai')

    assert_equal %w[claude.ai], @manager.notification_permissions.map(&:host)
  end

  # --- Certificate exceptions ---

  # Unlike the other three, WebKit reports the failing host directly, so no URL
  # parsing happens on this path.
  def test_trust_certificate_takes_a_host
    permission = @manager.trust_certificate('localhost:8443')

    assert_equal 'localhost:8443', permission.host
    assert_equal NOW, permission.granted_at
    assert @manager.certificate_trusted?('localhost:8443')
  end

  def test_certificates_are_untrusted_until_an_exception_is_added
    refute @manager.certificate_trusted?('localhost')
  end

  def test_certificate_trust_is_host_specific
    @manager.trust_certificate('localhost:8443')

    refute @manager.certificate_trusted?('localhost')
  end

  def test_certificates_are_untrusted_for_a_missing_host
    refute @manager.certificate_trusted?(nil)
    assert_nil @manager.trust_certificate(nil)
  end

  def test_revoke_certificate_exception_takes_a_host
    @manager.trust_certificate('localhost')

    assert @manager.revoke_certificate_exception('localhost')
    refute @manager.certificate_trusted?('localhost')
  end

  def test_certificate_exceptions_lists_what_is_stored
    @manager.trust_certificate('localhost')

    assert_equal %w[localhost], @manager.certificate_exceptions.map(&:host)
  end

  # --- Separation between the four stores ---

  def test_each_permission_kind_has_its_own_store
    @manager.allow_popups('https://example.com')

    refute @manager.notifications_allowed?('https://example.com')
    refute @manager.certificate_trusted?('example.com')
    refute @manager.media_allowed?('https://example.com', :audio)
  end
end
