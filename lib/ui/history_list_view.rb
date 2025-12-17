require 'gtk3'
require 'cgi'

# Sidebar view for displaying browsing history
class HistoryListView
  attr_reader :list_widget, :search_entry

  # Creates a new history list view
  #
  # @param history_manager [HistoryManager] History manager for querying visits
  # @param favicon_image_creator [Proc] Proc that creates favicon images: ->(favicon_data) { Gtk::Image }
  def initialize(history_manager, favicon_image_creator)
    @history_manager = history_manager
    @favicon_image_creator = favicon_image_creator
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Search state
    @search_query = nil

    # Search entry widget (to be added to sidebar header)
    @search_entry = Gtk::SearchEntry.new
    @search_entry.placeholder_text = "Search history..."
    @search_entry.signal_connect("search-changed") do
      query = @search_entry.text.strip
      @search_query = query.empty? ? nil : query
      refresh
    end

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

    # Get history items (search results or recent visits)
    if @search_query && !@search_query.empty?
      # Use search results - need to convert to visit format
      pages = @history_manager.search(@search_query, limit)

      if pages.empty?
        # Show "no results" message
        no_results_label = Gtk::Label.new("No results found for \"#{@search_query}\"")
        no_results_label.margin = 20
        no_results_label.style_context.add_class("dim-label")
        @list_widget.add(no_results_label)
      else
        pages.each do |page|
          # Convert page format to visit format for create_history_row
          visit = {
            'visit_id' => page['id'],  # Use page id as visit id for delete functionality
            'uri' => page['uri'],
            'page_title' => page['title'],
            'visit_title' => page['title'],
            'visited_at' => page['last_visited_at'],
            'favicon' => nil  # Favicon not included in search results
          }
          row = create_history_row(visit)
          @list_widget.add(row)
        end
      end
    else
      # Show recent visits
      visits = @history_manager.recent_visits(limit)

      visits.each do |visit|
        row = create_history_row(visit)
        @list_widget.add(row)
      end
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

    # Remove button
    remove_button = Gtk::Button.new(label: "×")
    remove_button.relief = :none
    remove_button.signal_connect("clicked") do
      @history_manager.delete_visit(visit['visit_id'])
      refresh()  # Refresh after removal
      true  # Stop event propagation to prevent row-activated signal
    end
    hbox.pack_start(remove_button, expand: false, fill: false, padding: 0)

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
