require 'minitest/autorun'
require_relative '../../lib/managers/popup_manager'

# Stands in for Managers::SitePermissionManager -- only the popup half of it
# is reachable from here.
class MockPopupPermissions
  attr_reader :allowed_urls

  def initialize(allowed_hosts = [])
    @allowed_hosts = allowed_hosts
    @allowed_urls = []
  end

  def popups_allowed?(url)
    host = Domain::UrlHost.host(url)
    !!host && @allowed_hosts.include?(host)
  end

  def allow_popups(url)
    @allowed_urls << url
    host = Domain::UrlHost.host(url)
    @allowed_hosts << host if host
    host
  end
end

class PopupManagerTest < Minitest::Test
  def setup
    @permissions = MockPopupPermissions.new(['trusted.example.com'])
    @manager = Managers::PopupManager.new(site_permissions: @permissions)
  end

  # --- Requests from a page ---

  def test_a_trusted_site_opens_its_popup_in_a_new_tab
    decision = @manager.request('https://trusted.example.com/popup')

    assert_equal :new_tab, decision.action
    assert_equal 'https://trusted.example.com/popup', decision.url
  end

  def test_an_untrusted_site_is_blocked_and_the_user_is_asked
    decision = @manager.request('https://ads.example.com/popup')

    assert_equal :prompt, decision.action
    assert_equal 'ads.example.com', decision.host
  end

  def test_an_oauth_popup_from_a_trusted_site_gets_its_own_window
    @permissions.allow_popups('https://accounts.google.com')

    decision = @manager.request('https://accounts.google.com/o/oauth2/auth')

    assert_equal :oauth_window, decision.action
  end

  def test_a_request_with_no_destination_is_blocked_silently
    decision = @manager.request(nil)

    assert_equal :block, decision.action
  end

  def test_asking_does_not_grant_anything
    @manager.request('https://ads.example.com/popup')

    assert_empty @permissions.allowed_urls
  end

  # --- The user allowing popups from the blocked-popup bar ---

  def test_allowing_grants_the_permission_to_the_destination_site
    @manager.allow_and_route('https://ads.example.com/popup')

    assert_equal ['https://ads.example.com/popup'], @permissions.allowed_urls
    assert @permissions.popups_allowed?('https://ads.example.com/other')
  end

  def test_allowing_routes_the_popup_that_was_blocked
    decision = @manager.allow_and_route('https://ads.example.com/popup')

    assert_equal :new_tab, decision.action
    assert_equal 'https://ads.example.com/popup', decision.url
  end

  def test_allowing_an_oauth_popup_routes_it_to_a_window
    decision = @manager.allow_and_route('https://appleid.apple.com/auth/authorize')

    assert_equal :oauth_window, decision.action
  end

  def test_allowing_a_second_time_is_harmless
    @manager.allow_and_route('https://ads.example.com/popup')
    decision = @manager.allow_and_route('https://ads.example.com/popup')

    assert_equal :new_tab, decision.action
  end
end
