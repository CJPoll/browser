require 'gtk3'
require 'cgi'

# Sidebar view for displaying browser tabs
class TabListView
  attr_reader :list_widget

  # Creates a new tab list view
  #
  # @param favicon_image_creator [Proc] Proc that creates favicon images: ->(favicon_data) { Gtk::Image }
  def initialize(favicon_image_creator)
    @favicon_image_creator = favicon_image_creator
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Callback invoked when tab is clicked
    # Signature: ->(tab_index) { ... }
    @on_tab_selected = nil

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_tab_clicked(row)
    end
  end

  # Sets callback to invoke when tab is selected
  #
  # @param callback [Proc] Callback proc accepting tab index: ->(index) { ... }
  # @return [void]
  def on_tab_selected=(callback)
    @on_tab_selected = callback
  end

  # Refreshes the tab list display
  #
  # @param tabs [Array<Tab>] Array of Tab objects
  # @param current_tab_index [Integer] Index of currently active tab
  # @return [void]
  def refresh(tabs, current_tab_index)
    # Clear existing items
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Add a row for each tab
    tabs.each_with_index do |tab, index|
      row = create_tab_row(tab, index)
      @list_widget.add(row)

      # Highlight the current tab
      if index == current_tab_index
        @list_widget.select_row(row)
      end
    end

    @list_widget.show_all
  end

  private

  # Creates a list box row for a tab
  #
  # @param tab [Tab] Tab object
  # @param index [Integer] Tab index in tabs array
  # @return [Gtk::ListBoxRow] Configured row widget
  def create_tab_row(tab, index)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = @favicon_image_creator.call(tab.favicon_data)
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = tab.title || "New Tab"
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..40])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    if tab.uri && !tab.uri.empty?
      url_label = Gtk::Label.new(tab.uri)
      url_label.halign = :start
      url_label.ellipsize = :middle
      url_label.max_width_chars = 30
      url_label.style_context.add_class("dim-label")
      vbox.pack_start(url_label, expand: false, fill: false, padding: 0)
    end

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    row.add(hbox)

    # Store the tab index in the row
    row.instance_variable_set(:@tab_index, index)

    row
  end

  # Handles tab row click
  #
  # @param row [Gtk::ListBoxRow] Clicked row
  # @return [void]
  def on_tab_clicked(row)
    tab_index = row.instance_variable_get(:@tab_index)
    @on_tab_selected.call(tab_index) if @on_tab_selected && tab_index
  end
end
