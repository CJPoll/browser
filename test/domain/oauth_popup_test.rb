require 'minitest/autorun'
require_relative '../../lib/domain/oauth_popup'

class OauthPopupTest < Minitest::Test
  # ========================================
  # Google
  # ========================================

  def test_google_accounts_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://accounts.google.com/o/oauth2/auth?client_id=1")
  end

  def test_host_matching_is_case_insensitive
    assert Domain::OauthPopup.popup?("https://ACCOUNTS.GOOGLE.COM/o/oauth2/auth")
  end

  def test_other_google_hosts_are_not_oauth_popups
    refute Domain::OauthPopup.popup?("https://mail.google.com/mail/u/0")
  end

  # ========================================
  # Firebase
  # ========================================

  def test_firebase_auth_handler_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://my-app.firebaseapp.com/__/auth/handler")
  end

  def test_firebase_host_without_an_auth_path_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://my-app.firebaseapp.com/index.html")
  end

  def test_apex_firebaseapp_host_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://firebaseapp.com/__/auth/handler")
  end

  def test_lookalike_firebase_host_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://evil-firebaseapp.com.attacker.test/__/auth/handler")
  end

  # ========================================
  # Apple and Microsoft
  # ========================================

  def test_apple_id_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://appleid.apple.com/auth/authorize")
  end

  def test_microsoft_online_login_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://login.microsoftonline.com/common/oauth2/authorize")
  end

  def test_microsoft_live_login_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://login.live.com/oauth20_authorize.srf")
  end

  # ========================================
  # GitHub
  # ========================================

  def test_github_oauth_login_path_is_an_oauth_popup
    assert Domain::OauthPopup.popup?("https://github.com/login/oauth/authorize?client_id=1")
  end

  def test_github_sign_in_page_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://github.com/login")
  end

  def test_github_repository_page_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://github.com/anthropics/claude-code")
  end

  # ========================================
  # Everything else
  # ========================================

  def test_unrelated_url_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://example.com/login")
  end

  def test_nil_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?(nil)
  end

  def test_empty_string_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("")
  end

  def test_unparseable_url_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("https://exa mple.com")
  end

  def test_url_without_a_host_is_not_an_oauth_popup
    refute Domain::OauthPopup.popup?("/login/oauth/authorize")
  end
end
