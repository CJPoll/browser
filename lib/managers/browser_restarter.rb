# frozen_string_literal: true

require_relative 'session_manager'
require_relative '../adapters/process_launcher'

module Managers
  # Restarts the browser on the current code.
  #
  # The reload shortcut is a development convenience: the open tabs are saved,
  # a fresh process is started from the same script, and the window that asked
  # closes -- the new process restores the session it left behind. The order
  # matters, which is why it lives here rather than in the window.
  class BrowserRestarter
    RUBY_COMMAND = 'ruby'

    # @param session_manager [Managers::SessionManager] Carries the tabs across
    # @param process_launcher [Adapters::ProcessLauncher] Starts the new process
    def initialize(session_manager: Managers::SessionManager.new,
                   process_launcher: Adapters::ProcessLauncher.new)
      @session_manager = session_manager
      @process_launcher = process_launcher
    end

    # Saves the session and starts the replacement process
    #
    # The caller closes its window afterwards; this method does not, so that a
    # failure to launch leaves the user with the browser they had.
    #
    # @param tab_uris [Array<String, nil>] Each tab's URI, in tab order
    # @param current_tab_index [Integer, nil] Index of the active tab
    # @param script_path [String] Entry point to run again
    # @return [Integer] Process id of the replacement
    def restart(tab_uris, current_tab_index, script_path)
      @session_manager.save(tab_uris, current_tab_index)
      @process_launcher.launch(RUBY_COMMAND, script_path)
    end
  end
end
