#!/usr/bin/env ruby
# Toy Browser - GTK3-based web browser with queue management
# Entry point: Creates BrowserApplication and starts GTK main loop

require 'fileutils'

# Capture ARGV before GTK Application consumes it
ORIGINAL_ARGV = ARGV.dup

# Parse --new-window flag
NEW_WINDOW_FLAG = ORIGINAL_ARGV.delete('--new-window') ? true : false

# IPC file for passing URLs between instances
IPC_DIR = File.join(Dir.home, '.local/share/toy-browser')
FileUtils.mkdir_p(IPC_DIR)
IPC_URL_FILE = File.join(IPC_DIR, 'pending-url')

# Write URL to IPC file for the primary instance to pick up
# This works for both first launch and subsequent launches
if ORIGINAL_ARGV.length > 0 && !ORIGINAL_ARGV[0].empty?
  File.write(IPC_URL_FILE, "#{ORIGINAL_ARGV[0]}\n#{Time.now.to_f}\n#{NEW_WINDOW_FLAG}")
elsif NEW_WINDOW_FLAG
  # --new-window without URL - open blank window
  File.write(IPC_URL_FILE, "\n#{Time.now.to_f}\n#{NEW_WINDOW_FLAG}")
end

require 'gtk3'
require 'webkit2-gtk'
require 'cgi'
require 'json'
require 'net/http'
require 'uri'
require_relative 'history_manager'
require_relative 'queue_manager'
require_relative 'download_manager'
require_relative 'video_popout_window'
require_relative 'lib/managers/web_context_manager'
require_relative 'lib/managers/settings_manager'
require_relative 'lib/managers/session_manager'
require_relative 'lib/managers/queue_metadata_worker'
require_relative 'lib/managers/favicon_manager'
require_relative 'lib/managers/popup_manager'
require_relative 'lib/managers/media_permission_manager'
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
