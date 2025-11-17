require 'gtk3'

# GTK Application managing browser lifecycle and single-instance behavior
class BrowserApplication < Gtk::Application
  # IPC file for passing URLs between instances
  IPC_DIR = File.join(Dir.home, '.local/share/toy-browser')
  IPC_URL_FILE = File.join(IPC_DIR, 'pending-url')

  # Creates a new browser application
  # Captures command-line arguments before GTK consumes them
  #
  # @param original_argv [Array<String>] Command-line arguments (ARGV.dup)
  def initialize(original_argv)
    super("com.example.browser", Gio::ApplicationFlags::HANDLES_OPEN | Gio::ApplicationFlags::HANDLES_COMMAND_LINE)

    @original_argv = original_argv
    @main_window = nil
    @last_ipc_check = Time.now.to_f

    # Set up signal handlers
    setup_signals
  end

  private

  # Sets up GTK Application signal handlers
  #
  # @return [void]
  def setup_signals
    signal_connect("activate") { on_activate }
    signal_connect("command-line") { |app, command_line| on_command_line(app, command_line) }
    signal_connect("open") { |app, files, hint| on_open(app, files, hint) }
  end

  # Handles application activation (first launch or subsequent activation)
  #
  # @return [void]
  def on_activate
    if @main_window.nil?
      # First launch - create new window
      @main_window = BrowserWindow.new
      @main_window.set_application(self)
      @main_window.show_all

      # Set up IPC file monitoring for URLs from other instances
      setup_ipc_monitoring
    else
      # Window already exists - just present it
      @main_window.present
    end
  end

  # Sets up IPC file monitoring timer
  # Checks every 500ms for URLs written by second instances
  #
  # @return [void]
  def setup_ipc_monitoring
    GLib::Timeout.add(500) do
      if File.exist?(IPC_URL_FILE)
        begin
          content = File.read(IPC_URL_FILE)
          url, timestamp = content.split("\n")
          timestamp = timestamp.to_f

          # Only process if this is a new URL (timestamp after last check)
          if timestamp > @last_ipc_check
            @main_window.create_new_tab(url)
            @main_window.present
            @last_ipc_check = timestamp
            # Delete the file after processing
            File.delete(IPC_URL_FILE)
          end
        rescue => e
          warn "Error reading IPC file: #{e.message}"
        end
      end
      true  # Continue timer
    end
  end

  # Handles command-line invocation
  #
  # @param application [Gtk::Application] Application instance
  # @param command_line [Gio::ApplicationCommandLine] Command line object
  # @return [Integer] Exit status code
  def on_command_line(application, command_line)
    # Get or create the main window
    application.activate if @main_window.nil?

    # Check if a URL was passed in original_argv
    if @original_argv.length > 0 && !@original_argv[0].to_s.empty?
      url = @original_argv[0]
      begin
        tabs = @main_window.instance_variable_get(:@tabs)
        first_tab_uri = tabs.first&.uri

        # If the first tab is about:blank, navigate it to the URL instead of creating a new tab
        if first_tab_uri == "about:blank"
          tabs.first.webview.load_uri(url)
        else
          # Otherwise create a new tab
          @main_window.create_new_tab(url)
        end

        # Clear original_argv so we don't re-open it on next signal
        @original_argv.clear
      rescue => e
        warn "Error loading URL: #{e.message}"
      end
    end

    # Bring window to front
    @main_window.present if @main_window

    0  # Return status code
  end

  # Handles file/URL opening via xdg-open
  #
  # @param application [Gtk::Application] Application instance
  # @param files [Array<Gio::File>] Files to open
  # @param hint [String] Hint for how to open files
  # @return [void]
  def on_open(application, files, hint)
    # Get or create the main window
    if @main_window.nil?
      @main_window = BrowserWindow.new
      @main_window.set_application(application)
      @main_window.show_all
    end

    # Open each file/URL as a new tab
    files.each do |file|
      url = file.uri
      begin
        @main_window.create_new_tab(url)
      rescue => e
        warn "Error creating tab: #{e.message}"
      end
    end

    # Bring window to front
    @main_window.present
  end
end
