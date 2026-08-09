# frozen_string_literal: true

require_relative 'site_permission_manager'
require_relative '../domain/permission_decision'
require_relative '../domain/url_host'

module Managers
  # What happens when a site asks for something it may already have been
  # granted: the camera or microphone, permission to send notifications, or to
  # be trusted despite a failed certificate check.
  #
  # Each method answers with a `Domain::PermissionDecision` -- allow, ask, or
  # stay out of it. Acting on the answer (calling back into WebKit, showing a
  # bar) belongs to the Framework, which is the only bucket holding the
  # request objects and the widgets.
  #
  # `Managers::SitePermissionManager` owns the stored permissions themselves;
  # this manager owns the policy applied when one is asked for.
  class PermissionRequestManager
    # The only permission this browser answers a state query for. WebKit also
    # queries for geolocation and others; those are left to its own defaults.
    NOTIFICATIONS_QUERY = 'notifications'

    # @param site_permissions [Managers::SitePermissionManager] Store of what
    #   each site has already been granted
    def initialize(site_permissions: Managers::SitePermissionManager.new)
      @site_permissions = site_permissions
    end

    # Decides what to do about a camera/microphone request
    #
    # @param page_url [String, nil] URL of the page making the request
    # @param permission_type [Symbol] See Domain::MediaPermissionType
    # @return [Domain::PermissionDecision]
    def media_request(page_url, permission_type)
      Domain::PermissionDecision.for(
        url: page_url,
        granted: @site_permissions.media_allowed?(page_url, permission_type)
      )
    end

    # Decides what to do about a request to send web notifications
    #
    # @param page_url [String, nil] URL of the page making the request
    # @return [Domain::PermissionDecision]
    def notification_request(page_url)
      Domain::PermissionDecision.for(
        url: page_url,
        granted: @site_permissions.notifications_allowed?(page_url)
      )
    end

    # Decides what to do about a page whose TLS certificate failed validation
    #
    # @param failing_uri [String, nil] URI WebKit reported the failure for
    # @return [Domain::PermissionDecision] `:allow` means the user has trusted
    #   this host before, so the certificate may be accepted and the page
    #   reloaded
    def certificate_request(failing_uri)
      Domain::PermissionDecision.for(
        url: failing_uri,
        granted: @site_permissions.certificate_trusted?(Domain::UrlHost.host(failing_uri))
      )
    end

    # Answers a site asking what state a permission is in, without prompting
    #
    # @param permission_name [String, nil] Permission being queried
    # @param origin [String, nil] Security origin asking -- WebKit supplies an
    #   origin here rather than a page URL
    # @return [Symbol] `:granted`, `:prompt`, or `:unhandled` for a permission
    #   this browser does not track
    def permission_state(permission_name, origin)
      return :unhandled unless permission_name == NOTIFICATIONS_QUERY

      @site_permissions.notifications_allowed?(origin) ? :granted : :prompt
    end
  end
end
