require 'gtk3'

# Sidebar container managing tabs/history/queue view switching
class Sidebar
  # TODO (Phase 6): Consider moving queue reordering logic into Sidebar methods
  # to eliminate direct GTK widget manipulation from BrowserWindow
  attr_reader :widget, :visible, :mode, :width, :queue_list_widget

  # Creates a new sidebar
  #
  # @param view_components [Hash] Hash of view components:
  #   - :tab_list_view => TabListView instance
  #   - :history_list_view => HistoryListView instance
  #   - :queue_list_view => QueueListView instance
  # @param callbacks [Hash] Hash of callback procs:
  #   - :get_tabs => -> { [@tabs, @current_tab_index] }
  #   - :get_current_tab => -> { Tab or nil }
  #   - :get_queue_count => -> { Integer }
  #   - :get_paned => -> { Gtk::Paned widget }
  # @param initial_width [Integer] Initial sidebar width in pixels
  def initialize(view_components, callbacks, initial_width: 300)
    @view_components = view_components
    @callbacks = callbacks
    @width = initial_width
    @visible = true
    @mode = :tabs  # Can be :tabs, :history, or :queue

    # Expose queue_list_widget for move operations
    @queue_list_widget = @view_components[:queue_list_view].list_widget

    # Create sidebar box
    @widget = Gtk::Box.new(:vertical, 0)

    # Sidebar header
    @header = Gtk::Label.new
    @header.markup = "<b>Tabs</b>"
    @header.margin_top = 10
    @header.margin_bottom = 10
    @widget.pack_start(@header, expand: false, fill: false, padding: 0)

    # Scrolled window for list
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)

    # Container to hold tabs, history, or queue list
    @content = Gtk::Box.new(:vertical, 0)
    @content.pack_start(@view_components[:tab_list_view].list_widget,
                        expand: true, fill: true, padding: 0)

    scrolled.add(@content)
    @widget.pack_start(scrolled, expand: true, fill: true, padding: 0)

    @widget.set_size_request(300, -1)
  end

  # Shows tabs view in sidebar
  #
  # @return [void]
  def show_tabs
    # If already showing tabs sidebar, toggle it off
    if @visible && @mode == :tabs
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :tabs
    @header.markup = "<b>Tabs</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add tabs list
    @content.pack_start(@view_components[:tab_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Refresh tabs
    tabs, current_tab_index = @callbacks[:get_tabs].call
    @view_components[:tab_list_view].refresh(tabs, current_tab_index)
  end

  # Shows history view in sidebar
  #
  # @return [void]
  def show_history
    # If already showing history sidebar, toggle it off
    if @visible && @mode == :history
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :history
    @header.markup = "<b>Browsing History</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add history list
    @content.pack_start(@view_components[:history_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Refresh history
    @view_components[:history_list_view].refresh(50)
  end

  # Shows queue view in sidebar
  #
  # @return [void]
  def show_queue
    # If already showing queue sidebar, toggle it off
    if @visible && @mode == :queue
      hide_sidebar
      return
    end

    # Show sidebar if it's hidden
    show_sidebar if !@visible

    @mode = :queue
    queue_count = @callbacks[:get_queue_count].call
    @header.markup = "<b>Queue (#{queue_count})</b>"

    # Clear sidebar content
    @content.children.each { |child| @content.remove(child) }

    # Add queue list
    @content.pack_start(@view_components[:queue_list_view].list_widget,
                        expand: true, fill: true, padding: 0)
    @content.show_all

    # Refresh queue
    current_tab = @callbacks[:get_current_tab].call
    current_url = current_tab&.webview&.uri
    @view_components[:queue_list_view].refresh(current_url)
  end

  # Refreshes the currently active view
  #
  # @return [void]
  def refresh_current_view
    case @mode
    when :tabs
      tabs, current_tab_index = @callbacks[:get_tabs].call
      @view_components[:tab_list_view].refresh(tabs, current_tab_index)
    when :history
      @view_components[:history_list_view].refresh(50)
    when :queue
      current_tab = @callbacks[:get_current_tab].call
      current_url = current_tab&.webview&.uri
      @view_components[:queue_list_view].refresh(current_url)
    end
  end

  # Toggles sidebar visibility
  #
  # @return [void]
  def toggle
    if @visible
      hide_sidebar
    else
      show_sidebar
    end
  end

  # Updates the sidebar width
  #
  # @param width [Integer] New width in pixels
  # @return [void]
  def update_width(width)
    @width = width if width > 0
  end

  # Updates the queue header with new count
  #
  # @param count [Integer] New queue count
  # @return [void]
  def update_queue_header(count)
    @header.markup = "<b>Queue (#{count})</b>" if @mode == :queue
  end

  private

  # Shows the sidebar widget
  def show_sidebar
    @widget.show_all
    paned = @callbacks[:get_paned].call
    paned.set_position(@width)
    @visible = true
  end

  # Hides the sidebar widget
  def hide_sidebar
    @visible = false
    @widget.hide
    paned = @callbacks[:get_paned].call
    paned.set_position(0)
  end
end
