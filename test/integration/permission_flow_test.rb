require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../../lib/managers/site_permission_manager'
require_relative '../../lib/managers/popup_manager'
require_relative '../../lib/managers/permission_request_manager'
require_relative '../../lib/repositories/popup_exception_repository'
require_relative '../../lib/repositories/media_permission_repository'
require_relative '../../lib/repositories/notification_permission_repository'
require_relative '../../lib/repositories/certificate_exception_repository'
require_relative '../support/test_clock'

# Integration test for the site-permission flows without mocks
# Tests: Repositories <-> SitePermissionManager <-> PopupManager /
#        PermissionRequestManager <-> Domain
#
# The pattern each flow follows is the same one BrowserWindow drives: a site
# asks, the user is prompted, the user says yes, and the next request from
# that site is answered without asking again.
class PermissionFlowTest < Minitest::Test
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @temp_dir = Dir.mktmpdir('permissions')
    @clock = TestClock.new(NOW)

    @popup_repository = Repositories::PopupExceptionRepository.new(db_path: db_path('popups'))
    @media_repository = Repositories::MediaPermissionRepository.new(db_path: db_path('media'))
    @notification_repository = Repositories::NotificationPermissionRepository.new(db_path: db_path('notifications'))
    @certificate_repository = Repositories::CertificateExceptionRepository.new(db_path: db_path('certificates'))

    @site_permissions = Managers::SitePermissionManager.new(
      popup_repository: @popup_repository,
      media_repository: @media_repository,
      notification_repository: @notification_repository,
      certificate_repository: @certificate_repository,
      clock: @clock
    )
    @popup_manager = Managers::PopupManager.new(site_permissions: @site_permissions)
    @permission_requests = Managers::PermissionRequestManager.new(site_permissions: @site_permissions)
  end

  def teardown
    [@popup_repository, @media_repository, @notification_repository, @certificate_repository].each(&:close)
    FileUtils.remove_entry(@temp_dir)
  end

  def test_happy_path_allowing_a_blocked_popup_and_being_remembered
    # 1. A page tries to open a popup; the site has no permission yet
    decision = @popup_manager.request('https://app.example.com/checkout')

    assert_equal :prompt, decision.action
    assert_equal 'app.example.com', decision.host

    # 2. The user clicks Allow on the bar: the popup opens where it belongs
    allowed = @popup_manager.allow_and_route('https://app.example.com/checkout')

    assert_equal :new_tab, allowed.action

    # 3. The next popup from that site is not blocked
    assert_equal :new_tab, @popup_manager.request('https://app.example.com/receipt').action

    # 4. And the grant is on record for the permissions window to revoke
    granted = @site_permissions.popup_permissions

    assert_equal ['app.example.com'], granted.map(&:host)
    assert_equal NOW, granted.first.granted_at
  end

  def test_an_oauth_popup_from_an_allowed_site_is_routed_to_its_own_window
    @popup_manager.allow_and_route('https://accounts.google.com/o/oauth2/auth')

    assert_equal :oauth_window, @popup_manager.request('https://accounts.google.com/o/oauth2/auth').action
  end

  def test_happy_path_granting_the_camera_and_being_remembered
    assert_equal :prompt, @permission_requests.media_request('https://meet.example.com/room', :audio_video).action

    # The bar's Allow button grants it for the host
    @site_permissions.allow_media('https://meet.example.com', :audio_video)

    assert_equal :allow, @permission_requests.media_request('https://meet.example.com/room', :audio_video).action

    # A different device is a different grant, so the user is asked again
    assert_equal :prompt, @permission_requests.media_request('https://meet.example.com/room', :video).action
  end

  def test_happy_path_granting_notifications_and_answering_a_later_state_query
    assert_equal :prompt, @permission_requests.notification_request('https://chat.example.com/inbox').action
    assert_equal :prompt, @permission_requests.permission_state('notifications', 'chat.example.com')

    @site_permissions.allow_notifications('https://chat.example.com')

    assert_equal :allow, @permission_requests.notification_request('https://chat.example.com/inbox').action
    assert_equal :granted, @permission_requests.permission_state('notifications', 'chat.example.com')

    # Revoking from the permissions window puts the site back to asking
    assert @site_permissions.revoke_notification_permission('chat.example.com')
    assert_equal :prompt, @permission_requests.permission_state('notifications', 'chat.example.com')
  end

  def test_happy_path_trusting_a_certificate_and_being_remembered
    failing_uri = 'https://self-signed.example.com/dashboard'

    assert_equal :prompt, @permission_requests.certificate_request(failing_uri).action

    # The bar's Allow button trusts the host WebKit reported
    @site_permissions.trust_certificate('self-signed.example.com')

    decision = @permission_requests.certificate_request(failing_uri)

    assert_equal :allow, decision.action
    assert_equal 'self-signed.example.com', decision.host, 'the host WebKit is told to trust'
  end

  def test_permissions_do_not_leak_between_kinds
    @site_permissions.allow_notifications('https://one.example.com')

    assert_equal :prompt, @popup_manager.request('https://one.example.com/popup').action
    assert_equal :prompt, @permission_requests.media_request('https://one.example.com/call', :audio).action
    assert_equal :prompt, @permission_requests.certificate_request('https://one.example.com/').action
  end

  private

  def db_path(name)
    File.join(@temp_dir, "#{name}.db")
  end
end
