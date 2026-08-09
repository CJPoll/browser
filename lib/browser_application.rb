require 'gtk3'
require_relative 'managers/ipc_manager'

# GTK Application managing browser lifecycle and single-instance behavior
class BrowserApplication < Gtk::Application
  # What the first tab shows when nobody has navigated it anywhere
  UNTOUCHED_FIRST_TAB_URIS = ['https://www.example.com/', 'https://www.example.com'].freeze

  # Creates a new browser application
  def initialize
    super("com.example.browser", Gio::ApplicationFlags::HANDLES_OPEN | Gio::ApplicationFlags::HANDLES_COMMAND_LINE)

    @main_window = nil
    @windows = []  # Track all windows for cleanup
    # Requests from other instances arrive through this manager, which also
    # remembers which ones have already been acted on
    @ipc_manager = Managers::IpcManager.new

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

  # Acts on a request from another instance, if one is waiting
  #
  # @return [void]
  def process_ipc_file
    request = @ipc_manager.take_pending_request
    return unless request

    if request.new_window?
      # Create a new window
      window = create_window(request.url? ? request.url : nil)
      window.show_all
      window.present
    elsif request.url?
      # Open URL in existing window
      open_in_main_window(request.url)
    end
  rescue => e
    warn "Error handling IPC request: #{e.message}"
  end

  # Opens a URL in the window that is already up
  #
  # @param url [String] URL to open
  # @return [void]
  def open_in_main_window(url)
    # A window still showing the page it opened on has nothing worth keeping,
    # so the URL replaces it rather than opening a tab beside it
    if UNTOUCHED_FIRST_TAB_URIS.include?(@main_window.first_tab_uri)
      @main_window.load_url_in_first_tab(url)
    else
      @main_window.create_new_tab(url)
    end
    @main_window.present
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
    window.load_url_in_first_tab(url) if url && !url.empty?

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
