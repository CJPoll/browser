#!/usr/bin/env ruby

require 'gtk3'
require 'webkit2-gtk'
require 'cgi'
require 'fileutils'
require_relative 'history_manager'

class BrowserWindow < Gtk::Window
  def initialize
    super

    set_title("Toy Browser")
    set_default_size(1200, 768)

    # Initialize history manager
    @history_manager = HistoryManager.new

    # Hash to store visit data for each row
    @row_data = {}

    # Sidebar state
    @sidebar_visible = true
    @sidebar_width = 300

    # Zen mode state
    @zen_mode = false
    @sidebar_visible_before_zen = true

    # Create layout
    vbox = ::Gtk::Box.new(:vertical, 0)
    add(vbox)

    # Toolbar
    @toolbar = ::Gtk::Box.new(:horizontal, 5)
    @toolbar.margin_top = 5
    @toolbar.margin_bottom = 5
    @toolbar.margin_start = 5
    @toolbar.margin_end = 5
    vbox.pack_start(@toolbar, expand: false, fill: false, padding: 0)

    # Sidebar toggle button
    @sidebar_toggle = ::Gtk::Button.new(label: "☰")
    @sidebar_toggle.signal_connect("clicked") { toggle_sidebar }
    @toolbar.pack_start(@sidebar_toggle, expand: false, fill: false, padding: 0)

    # Back button
    @back_button = ::Gtk::Button.new(label: "⬅")
    @back_button.signal_connect("clicked") { on_back }
    @toolbar.pack_start(@back_button, expand: false, fill: false, padding: 0)

    # Forward button
    @forward_button = ::Gtk::Button.new(label: "➡")
    @forward_button.signal_connect("clicked") { on_forward }
    @toolbar.pack_start(@forward_button, expand: false, fill: false, padding: 0)

    # URL entry
    @url_entry = ::Gtk::Entry.new
    @url_entry.text = "https://www.example.com"
    @url_entry.signal_connect("activate") { on_load_url }
    @toolbar.pack_start(@url_entry, expand: true, fill: true, padding: 0)

    # Go button
    go_button = ::Gtk::Button.new(label: "Go")
    go_button.signal_connect("clicked") { on_load_url }
    @toolbar.pack_start(go_button, expand: false, fill: false, padding: 0)

    # Horizontal paned for sidebar and content
    @paned = Gtk::Paned.new(:horizontal)
    vbox.pack_start(@paned, expand: true, fill: true, padding: 0)

    # Left sidebar for history
    @sidebar = create_sidebar
    @paned.pack1(@sidebar, resize: false, shrink: true)
    @paned.set_position(@sidebar_width)  # Sidebar width

    # WebView with persistent storage
    web_context = create_web_context
    @webview = WebKit2Gtk::WebView.new(context: web_context)
    @webview.signal_connect("notify::uri") { on_uri_changed }
    @webview.signal_connect("load-changed") { |_webview, load_event| on_load_changed(load_event) }

    scrolled = Gtk::ScrolledWindow.new
    scrolled.add(@webview)
    @paned.pack2(scrolled, resize: true, shrink: false)

    # Load initial page
    @webview.load_uri("https://www.example.com")

    # Populate history
    refresh_history

    # Keyboard shortcuts
    signal_connect("key-press-event") do |widget, event|
      if event.state.control_mask?
        case event.keyval
        when Gdk::Keyval::KEY_l
          # Ctrl+L: Focus and select URL bar
          # In zen mode, show toolbar temporarily
          if @zen_mode
            @toolbar.show_all
          end
          @url_entry.grab_focus
          @url_entry.select_region(0, -1)
          true  # Event handled
        when Gdk::Keyval::KEY_b
          # Ctrl+B: Toggle sidebar (unless in zen mode)
          toggle_sidebar unless @zen_mode
          true  # Event handled
        when Gdk::Keyval::KEY_r
          # Ctrl+R: Refresh page
          @webview.reload
          true  # Event handled
        else
          false  # Event not handled
        end
      else
        case event.keyval
        when Gdk::Keyval::KEY_F11
          # F11: Toggle zen mode
          toggle_zen_mode
          true  # Event handled
        else
          false  # Event not handled
        end
      end
    end

    # Mouse button shortcuts (back/forward buttons)
    signal_connect("button-press-event") do |widget, event|
      case event.button
      when 4
        # Mouse back button
        @webview.go_back if @webview.can_go_back?
        true  # Event handled
      when 5
        # Mouse forward button
        @webview.go_forward if @webview.can_go_forward?
        true  # Event handled
      else
        false  # Event not handled
      end
    end
  end

  def on_load_url
    url = @url_entry.text
    url = "https://#{url}" unless url.start_with?("http://", "https://")
    @webview.load_uri(url)

    # In zen mode, hide toolbar after submitting URL
    if @zen_mode
      @toolbar.hide
    end
  end

  def on_uri_changed
    uri = @webview.uri
    @url_entry.text = uri if uri
  end

  def on_back
    @webview.go_back
  end

  def on_forward
    @webview.go_forward
  end

  def create_web_context
    # Get the default web context
    context = WebKit2Gtk::WebContext.default

    # Set up persistent cookie storage
    data_dir = File.join(Dir.home, '.local/share/toy-browser')
    FileUtils.mkdir_p(data_dir)

    cookies_file = File.join(data_dir, 'cookies.sqlite')
    cookie_manager = context.cookie_manager
    cookie_manager.set_persistent_storage(
      cookies_file,
      :sqlite
    )

    context
  end

  def create_sidebar
    sidebar_box = Gtk::Box.new(:vertical, 0)

    # Sidebar header
    header = Gtk::Label.new
    header.markup = "<b>Browsing History</b>"
    header.margin_top = 10
    header.margin_bottom = 10
    sidebar_box.pack_start(header, expand: false, fill: false, padding: 0)

    # History list
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)

    @history_list = Gtk::ListBox.new
    @history_list.selection_mode = :single
    @history_list.signal_connect("row-activated") { |_list, row| on_history_item_clicked(row) }

    scrolled.add(@history_list)
    sidebar_box.pack_start(scrolled, expand: true, fill: true, padding: 0)

    sidebar_box.set_size_request(300, -1)
    sidebar_box
  end

  def refresh_history
    # Clear existing items and data
    @history_list.children.each { |child| @history_list.remove(child) }
    @row_data.clear

    # Get recent history
    visits = @history_manager.recent_visits(50)

    visits.each do |visit|
      row = create_history_row(visit)
      @history_list.add(row)
    end

    @history_list.show_all
  end

  def create_history_row(visit)
    row = Gtk::ListBoxRow.new

    box = Gtk::Box.new(:vertical, 2)
    box.margin_top = 8
    box.margin_bottom = 8
    box.margin_start = 12
    box.margin_end = 12

    # Title
    title = visit['visit_title'] || visit['page_title'] || visit['uri']
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..60])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    box.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(visit['uri'])
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    box.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Time ago
    time_ago = format_time_ago(visit['visited_at'])
    time_label = Gtk::Label.new(time_ago)
    time_label.halign = :start
    time_label.style_context.add_class("dim-label")
    box.pack_start(time_label, expand: false, fill: false, padding: 0)

    row.add(box)
    @row_data[row] = visit  # Store visit data in hash
    row
  end

  def format_time_ago(timestamp)
    seconds_ago = Time.now.to_i - timestamp
    minutes_ago = seconds_ago / 60
    hours_ago = minutes_ago / 60
    days_ago = hours_ago / 24

    if seconds_ago < 60
      "Just now"
    elsif minutes_ago < 60
      "#{minutes_ago}m ago"
    elsif hours_ago < 24
      "#{hours_ago}h ago"
    elsif days_ago == 1
      "Yesterday"
    else
      "#{days_ago} days ago"
    end
  end

  def on_history_item_clicked(row)
    visit = @row_data[row]
    @webview.load_uri(visit['uri']) if visit
  end

  def on_load_changed(load_event)
    if load_event == :finished
      uri = @webview.uri
      title = @webview.title

      if uri && !uri.empty?
        @history_manager.record_visit(uri, title)
        refresh_history
      end
    end
  end

  def toggle_sidebar
    if @sidebar_visible
      # Hide sidebar
      @sidebar.hide
      @paned.set_position(0)
      @sidebar_visible = false
    else
      # Show sidebar
      @sidebar.show_all
      @paned.set_position(@sidebar_width)
      @sidebar_visible = true
    end
  end

  def toggle_zen_mode
    if @zen_mode
      # Exit zen mode - show toolbar and restore sidebar state
      @toolbar.show_all
      if @sidebar_visible_before_zen
        @sidebar.show_all
        @paned.set_position(@sidebar_width)
        @sidebar_visible = true
      end
      @zen_mode = false
    else
      # Enter zen mode - hide toolbar and sidebar
      @sidebar_visible_before_zen = @sidebar_visible
      @toolbar.hide

      if @sidebar_visible
        @sidebar.hide
        @paned.set_position(0)
        @sidebar_visible = false
      end

      @zen_mode = true
    end
  end
end

# Main application
app = Gtk::Application.new("com.example.browser", :flags_none)

app.signal_connect "activate" do |application|
  win = BrowserWindow.new
  win.set_application(application)
  win.show_all
end

app.run
