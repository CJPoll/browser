#!/usr/bin/env ruby
# Toy Browser - GTK3-based web browser with queue management
# Entry point: Creates BrowserApplication and starts GTK main loop

require_relative 'lib/managers/ipc_manager'

# Capture ARGV before GTK Application consumes it
ORIGINAL_ARGV = ARGV.dup

# Parse --new-window flag
NEW_WINDOW_FLAG = ORIGINAL_ARGV.delete('--new-window') ? true : false

# Publish the requested URL for the primary instance to pick up.
# This works for both first launch and subsequent launches: if no browser is
# running yet, the window this process creates reads its own request.
if ORIGINAL_ARGV.length > 0 && !ORIGINAL_ARGV[0].empty?
  Managers::IpcManager.new.publish(url: ORIGINAL_ARGV[0], new_window: NEW_WINDOW_FLAG)
elsif NEW_WINDOW_FLAG
  # --new-window without URL - open blank window
  Managers::IpcManager.new.publish(new_window: true)
end

require 'gtk3'
require 'webkit2-gtk'
require 'cgi'
require 'json'
require 'net/http'
require 'uri'
require_relative 'lib/ui/video_popout_window'
require_relative 'lib/managers/web_context_manager'
require_relative 'lib/managers/queue_metadata_worker'
require_relative 'lib/managers/favicon_manager'
require_relative 'lib/tab'
require_relative 'lib/ui/tab_list_view'
require_relative 'lib/ui/history_list_view'
require_relative 'lib/ui/queue_list_view'
require_relative 'lib/ui/tag_edit_dialog'
require_relative 'lib/ui/toolbar'
require_relative 'lib/ui/sidebar'
require_relative 'lib/ui/popup_notification_bar'
require_relative 'lib/ui/popup_window'
require_relative 'lib/ui/media_permission_bar'
require_relative 'lib/handlers/navigation_handler'
require_relative 'lib/handlers/mouse_handler'
require_relative 'lib/handlers/keyboard_handler'
require_relative 'lib/browser_window'
require_relative 'lib/browser_application'


# Main application entry point
app = BrowserApplication.new
app.run
