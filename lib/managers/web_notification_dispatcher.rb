# frozen_string_literal: true

require_relative '../adapters/system_notifier'
require_relative '../domain/web_notification'

module Managers
  # Shows a notification a web page asked for.
  #
  # The browser draws nothing itself: the notification is handed to the
  # desktop's notification daemon, attributed to the host that sent it.
  # Whether the site was allowed to notify at all is decided earlier, by
  # `Managers::PermissionRequestManager`.
  class WebNotificationDispatcher
    # @param notifier [Adapters::SystemNotifier] Desktop notification adapter
    def initialize(notifier: Adapters::SystemNotifier.new)
      @notifier = notifier
    end

    # Shows a notification
    #
    # @param title [String, nil] Title the page set
    # @param body [String, nil] Body the page set
    # @param page_url [String, nil] URL of the page that sent it
    # @return [Domain::WebNotification] What was actually shown, so the caller
    #   can report it without repeating the defaults
    def dispatch(title:, body:, page_url:)
      notification = Domain::WebNotification.for(title: title, body: body, page_url: page_url)

      @notifier.notify(
        title: notification.title,
        body: notification.body,
        app_name: notification.host
      )

      notification
    end
  end
end
