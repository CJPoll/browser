# frozen_string_literal: true

require_relative 'site_permission_manager'
require_relative '../domain/popup_decision'

module Managers
  # What happens when a page calls `window.open` (or follows a
  # `target="_blank"` link): the popup is opened where it belongs, or blocked
  # and the user offered the choice.
  #
  # Popups are blocked by default, so this manager sits between the WebKit
  # `create` signal and the stored per-site permission. It decides *what*
  # should happen; opening a window or a tab is the Framework's job, because
  # only the Framework holds the widgets.
  class PopupManager
    # @param site_permissions [Managers::SitePermissionManager] Store of which
    #   sites may open popups
    def initialize(site_permissions: Managers::SitePermissionManager.new)
      @site_permissions = site_permissions
    end

    # Decides what to do about a popup a page asked for
    #
    # @param destination_url [String, nil] URL the page wants to open
    # @return [Domain::PopupDecision]
    def request(destination_url)
      Domain::PopupDecision.for(
        url: destination_url,
        allowed: @site_permissions.popups_allowed?(destination_url)
      )
    end

    # Grants the destination site permission to open popups and says where the
    # popup that was blocked should now go.
    #
    # The grant is recorded against the *destination* host, which is the host
    # the blocked-popup bar named to the user.
    #
    # @param destination_url [String] URL that was blocked
    # @return [Domain::PopupDecision] Never a block or a prompt
    def allow_and_route(destination_url)
      @site_permissions.allow_popups(destination_url)

      Domain::PopupDecision.for(url: destination_url, allowed: true)
    end
  end
end
