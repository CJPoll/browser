# frozen_string_literal: true

module Adapters
  # Shows a desktop notification through the system's notification daemon.
  #
  # Web notifications are not drawn by the browser: they are handed to
  # `notify-send`, which any freedesktop.org notification daemon (dunst here)
  # picks up. Whether a site is allowed to notify at all is a permission
  # question, decided before this adapter is called.
  class SystemNotifier
    COMMAND = 'notify-send'
    DEFAULT_ICON = 'web-browser'

    # Runs a command as argv, never through a shell.
    SYSTEM_RUNNER = ->(*argv) { system(*argv) }

    # @param runner [#call] Receives the command and its arguments
    def initialize(runner: SYSTEM_RUNNER)
      @runner = runner
    end

    # Shows a notification
    #
    # @param title [String] Notification title
    # @param body [String] Notification body
    # @param app_name [String, nil] Name to attribute the notification to,
    #   usually the host that sent it
    # @param icon [String, nil] Icon name, or nil for no icon
    # @return [Boolean] True if the notification was handed off
    def notify(title:, body: '', app_name: nil, icon: DEFAULT_ICON)
      argv = [COMMAND]
      argv << "--app-name=#{app_name}" if app_name
      argv << "--icon=#{icon}" if icon
      argv << title.to_s << body.to_s

      !!@runner.call(*argv)
    end
  end
end
