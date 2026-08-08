# frozen_string_literal: true

require_relative '../domain/host_permission'
require_relative '../domain/media_permission_type'
require_relative '../domain/url_host'
require_relative '../repositories/popup_exception_repository'
require_relative '../repositories/media_permission_repository'
require_relative '../repositories/notification_permission_repository'
require_relative '../repositories/certificate_exception_repository'

module Managers
  # The permissions a site holds: opening popups, using the camera or
  # microphone, sending notifications, and being trusted despite a failed TLS
  # certificate check.
  #
  # Each kind has its own repository. This manager is where they meet: it
  # resolves whatever the caller has -- a page URL when a site makes a request,
  # a bare host when the user manages permissions -- to the hostname the
  # repositories key on, and stamps grants with the current time so that
  # Domain and the repositories never read the clock for it.
  #
  # Method naming follows the caller's input, deliberately:
  #
  # - `*_allowed?` / `allow_*` take a **URL**; the site making the request is
  #   identified by the page it is running on.
  # - `revoke_*` take a **host**; by then the permission is a stored record the
  #   user is pointing at, and there is no URL involved.
  # - the certificate methods take a **host** throughout, because WebKit
  #   reports the failing host directly.
  class SitePermissionManager
    def initialize(popup_repository: Repositories::PopupExceptionRepository.new,
                   media_repository: Repositories::MediaPermissionRepository.new,
                   notification_repository: Repositories::NotificationPermissionRepository.new,
                   certificate_repository: Repositories::CertificateExceptionRepository.new,
                   clock: -> { Time.now })
      @popup_repository = popup_repository
      @media_repository = media_repository
      @notification_repository = notification_repository
      @certificate_repository = certificate_repository
      @clock = clock
    end

    # --- Popups ---

    # @param url [String, nil] URL of the page requesting the popup
    # @return [Boolean] True if the site may open popups
    def popups_allowed?(url)
      host = Domain::UrlHost.host(url)
      return false unless host

      @popup_repository.exists?(host)
    end

    # @param url [String, nil] URL of the site to allow
    # @return [Domain::HostPermission, nil] The granted permission, or nil if
    #   the URL has no host or the site was already allowed
    def allow_popups(url)
      grant(@popup_repository, Domain::UrlHost.host(url))
    end

    # @param host [String, nil] Host to stop allowing popups for
    # @return [Boolean] True if a permission was revoked
    def revoke_popup_permission(host)
      @popup_repository.remove(host)
    end

    # @return [Array<Domain::HostPermission>] Sites allowed to open popups
    def popup_permissions
      @popup_repository.all
    end

    # --- Camera and microphone ---

    # @param url [String, nil] URL of the page requesting the devices
    # @param permission_type [Symbol, String, nil] See Domain::MediaPermissionType
    # @return [Boolean] True if the site holds that permission
    def media_allowed?(url, permission_type)
      host = Domain::UrlHost.host(url)
      return false unless host && Domain::MediaPermissionType.valid?(permission_type)

      @media_repository.exists?(host, permission_type)
    end

    # @param url [String, nil] URL of the site to allow
    # @param permission_type [Symbol, String, nil] See Domain::MediaPermissionType
    # @return [Domain::HostPermission, nil] The granted permission, or nil if
    #   the URL has no host, the type is unknown, or the site already held it
    def allow_media(url, permission_type)
      host = Domain::UrlHost.host(url)
      return nil unless host && Domain::MediaPermissionType.valid?(permission_type)

      @media_repository.add(
        Domain::HostPermission.new(
          host: host,
          permission_type: permission_type,
          granted_at: @clock.call
        )
      )
    end

    # @param host [String, nil] Host to revoke for
    # @param permission_type [Symbol, String, nil] Type to revoke, or nil for
    #   every media permission the host holds
    # @return [Boolean] True if anything was revoked
    def revoke_media_permission(host, permission_type = nil)
      @media_repository.remove(host, permission_type)
    end

    # @return [Array<Domain::HostPermission>] Granted media permissions
    def media_permissions
      @media_repository.all
    end

    # --- Web notifications ---

    # Accepts a URL, a security origin, or a bare hostname -- WebKit's
    # permission-state query supplies an origin rather than a page URL.
    #
    # @param url_or_host [String, nil] URL, origin, or hostname
    # @return [Boolean] True if the site may send notifications
    def notifications_allowed?(url_or_host)
      host = Domain::UrlHost.host_or_bare_name(url_or_host)
      return false unless host

      @notification_repository.exists?(host)
    end

    # @param url [String, nil] URL of the site to allow
    # @return [Domain::HostPermission, nil] The granted permission, or nil if
    #   the URL has no host or the site was already allowed
    def allow_notifications(url)
      grant(@notification_repository, Domain::UrlHost.host_or_bare_name(url))
    end

    # @param host [String, nil] Host to stop allowing notifications for
    # @return [Boolean] True if a permission was revoked
    def revoke_notification_permission(host)
      @notification_repository.remove(host)
    end

    # @return [Array<Domain::HostPermission>] Sites allowed to notify
    def notification_permissions
      @notification_repository.all
    end

    # --- TLS certificate exceptions ---

    # @param host [String, nil] Host WebKit reported the failure for
    # @return [Boolean] True if the user has trusted this host's certificate
    def certificate_trusted?(host)
      @certificate_repository.exists?(host)
    end

    # @param host [String, nil] Host to trust
    # @return [Domain::HostPermission, nil] The recorded exception, or nil if
    #   the host is missing or already trusted
    def trust_certificate(host)
      grant(@certificate_repository, host)
    end

    # @param host [String, nil] Host to stop trusting
    # @return [Boolean] True if an exception was revoked
    def revoke_certificate_exception(host)
      @certificate_repository.remove(host)
    end

    # @return [Array<Domain::HostPermission>] Hosts with certificate exceptions
    def certificate_exceptions
      @certificate_repository.all
    end

    private

    # Records a permission for a host in one of the host-keyed repositories.
    #
    # @param repository [#add] Repository to store into
    # @param host [String, nil] Resolved hostname
    # @return [Domain::HostPermission, nil]
    def grant(repository, host)
      return nil unless host

      repository.add(Domain::HostPermission.new(host: host, granted_at: @clock.call))
    end
  end
end
