require 'gtk3'
require 'cgi'

# Sidebar view for displaying browsing history
class HistoryListView
  attr_reader :list_widget

  # Creates a new history list view
  #
  # @param history_manager [HistoryManager] History manager for querying visits
  # @param favicon_image_creator [Proc] Proc that creates favicon images: ->(favicon_data) { Gtk::Image }
  def initialize(history_manager, favicon_image_creator)
    @history_manager = history_manager
    @favicon_image_creator = favicon_image_creator
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Callback invoked when history item is clicked
    # Signature: ->(visit) { ... } where visit is a hash with 'uri' key
    @on_history_item_selected = nil

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_history_item_clicked(row)
    end
  end

  # Sets callback to invoke when history item is selected
  #
  # @param callback [Proc] Callback proc accepting visit hash: ->(visit) { ... }
  # @return [void]
  def on_history_item_selected=(callback)
    @on_history_item_selected = callback
  end

  # Refreshes the history list display
  #
  # @param limit [Integer] Maximum number of visits to show (default: 50)
  # @return [void]
  def refresh(limit = 50)
    # Clear existing items
    @list_widget.children.each { |child| @list_widget.remove(child) }

    # Get recent history
    visits = @history_manager.recent_visits(limit)

    visits.each do |visit|
      row = create_history_row(visit)
      @list_widget.add(row)
    end

    @list_widget.show_all
  end

  private

  # Creates a list box row for a history visit
  #
  # @param visit [Hash] Visit data with keys: 'uri', 'visit_title'/'page_title', 'favicon', 'visited_at'
  # @return [Gtk::ListBoxRow] Configured row widget
  def create_history_row(visit)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = @favicon_image_creator.call(visit['favicon'])
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = visit['visit_title'] || visit['page_title'] || visit['uri']
    title_label = Gtk::Label.new
    title_label.markup = "<b>#{CGI.escapeHTML(title[0..60])}</b>"
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(visit['uri'])
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Time ago
    time_ago = format_time_ago(visit['visited_at'])
    time_label = Gtk::Label.new(time_ago)
    time_label.halign = :start
    time_label.style_context.add_class("dim-label")
    vbox.pack_start(time_label, expand: false, fill: false, padding: 0)

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    row.add(hbox)

    # Store visit data in the row
    row.instance_variable_set(:@visit_data, visit)

    row
  end

  # Handles history item click
  #
  # @param row [Gtk::ListBoxRow] Clicked row
  # @return [void]
  def on_history_item_clicked(row)
    visit = row.instance_variable_get(:@visit_data)
    @on_history_item_selected.call(visit) if @on_history_item_selected && visit
  end

  # Formats timestamp as human-readable relative time
  #
  # @param timestamp [Integer] Unix timestamp
  # @return [String] Human-readable time string
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
end
