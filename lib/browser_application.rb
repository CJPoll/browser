require 'gtk3'

# GTK Application managing browser lifecycle and single-instance behavior
class BrowserApplication < Gtk::Application
  # IPC file for passing URLs between instances
  IPC_DIR = File.join(Dir.home, '.local/share/toy-browser')
  IPC_URL_FILE = File.join(IPC_DIR, 'pending-url')

  # Creates a new browser application
  def initialize
    super("com.example.browser", Gio::ApplicationFlags::HANDLES_OPEN | Gio::ApplicationFlags::HANDLES_COMMAND_LINE)

    @main_window = nil
    @windows = []  # Track all windows for cleanup
    # Set to 0 so we process any IPC file written before app started
    @last_ipc_check = 0

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
      @main_window = create_window
      @main_window.show_all

      # Set up IPC file monitoring for URLs from this and other instances
      setup_ipc_monitoring
    else
      # Window already exists - just present it
      @main_window.present
    end
  end

  # Sets up IPC file monitoring timer
  # Checks every 100ms for URLs written by this or other instances
  #
  # @return [void]
  def setup_ipc_monitoring
    GLib::Timeout.add(100) do
      process_ipc_file
      true  # Continue timer
    end
  end

  # Process the IPC file if it exists and is newer than last check
  #
  # @return [void]
  def process_ipc_file
    return unless File.exist?(IPC_URL_FILE)

    begin
      content = File.read(IPC_URL_FILE)
      parts = content.split("\n")
      url = parts[0]
      timestamp = parts[1].to_f
      new_window = parts[2] == "true"

      # Only process if this is a new request (timestamp after last check)
      return unless timestamp > @last_ipc_check

      if new_window
        # Create a new window
        window = create_window(url.empty? ? nil : url)
        window.show_all
        window.present
      elsif url && !url.empty?
        # Open URL in existing window
        tabs = @main_window.instance_variable_get(:@tabs)
        first_tab_uri = tabs.first&.uri

        # If first tab is example.com (default), navigate it instead of creating new tab
        if first_tab_uri == "https://www.example.com/" || first_tab_uri == "https://www.example.com"
          tabs.first.webview.load_uri(url)
        else
          @main_window.create_new_tab(url)
        end
        @main_window.present
      end

      @last_ipc_check = timestamp
      # Delete the file after processing
      File.delete(IPC_URL_FILE)
    rescue => e
      warn "Error reading IPC file: #{e.message}"
    end
  end

  # Creates a new browser window and tracks it
  #
  # @param url [String, nil] Optional URL to load in the new window
  # @return [BrowserWindow] The created window
  def create_window(url = nil)
    window = BrowserWindow.new
    window.set_application(self)
    @windows << window

    # Remove from tracking when window is destroyed
    window.signal_connect("destroy") do
      @windows.delete(window)
      @main_window = @windows.first if @main_window == window
    end

    # Load URL if provided
    if url && !url.empty?
      # Navigate the first tab to the URL
      tabs = window.instance_variable_get(:@tabs)
      tabs.first&.webview&.load_uri(url)
    end

    window
  end

  # Handles command-line invocation
  # URLs are passed via IPC file since GTK Ruby bindings don't expose command_line.arguments properly
  #
  # @param application [Gtk::Application] Application instance
  # @param command_line [Gio::ApplicationCommandLine] Command line object
  # @return [Integer] Exit status code
  def on_command_line(application, command_line)
    # Get or create the main window
    application.activate if @main_window.nil?

    # Process any pending IPC file immediately (don't wait for timer)
    process_ipc_file

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
