require 'json'
require 'fileutils'

# Manages browser session persistence (tab URLs and current tab index)
class SessionManager
  # @param data_dir [String] Directory where session.json is stored
  def initialize(data_dir: nil)
    @data_dir = data_dir || File.join(Dir.home, '.local/share/toy-browser')
    @session_file = File.join(@data_dir, 'session.json')

    FileUtils.mkdir_p(@data_dir)
  end

  # Save current session to disk
  # @param tab_urls [Array<String>] Array of tab URLs to save
  # @param current_tab_index [Integer] Index of currently active tab
  # @return [void]
  def save_session(tab_urls, current_tab_index)
    session = {
      'tabs' => tab_urls,
      'current_tab_index' => current_tab_index
    }

    begin
      File.write(@session_file, JSON.pretty_generate(session))
    rescue => e
      puts "Failed to save session: #{e.message}"
    end
  end

  # Load session from disk and delete the session file
  # @return [Hash, nil] Session data with 'tabs' and 'current_tab_index', or nil if no session
  def load_session
    if File.exist?(@session_file)
      begin
        session = JSON.parse(File.read(@session_file))

        # Delete session file after loading
        File.delete(@session_file)

        return session
      rescue => e
        puts "Failed to load session: #{e.message}"
      end
    end

    nil
  end

  # Check if a session file exists
  # @return [Boolean]
  def session_exists?
    File.exist?(@session_file)
  end
end
