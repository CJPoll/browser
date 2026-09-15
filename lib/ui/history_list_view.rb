require 'gtk3'
require 'cgi'
require_relative '../domain/sidebar_title'

# Sidebar view for displaying browsing history
#
# Holds no manager, repository or adapter. History arrives through `get_*`
# callbacks and the remove button reports intent through `on_delete_visit`;
# the Framework (`BrowserWindow`) binds both to `Managers::HistoryManager`.
class HistoryListView
  attr_reader :list_widget, :search_entry

  # Creates a new history list view
  #
  # @param callbacks [Hash] Data sources and intents:
  #   - :create_favicon_image => ->(favicon_data) { Gtk::Image }
  #   - :get_search_results => ->(query, limit) { Array<Domain::Page> }
  #   - :get_recent_visits => ->(limit) { Array<Domain::Visit> }
  #   - :on_delete_visit => ->(visit_id) { ... }
  def initialize(callbacks = {})
    @callbacks = callbacks
    @list_widget = Gtk::ListBox.new
    @list_widget.selection_mode = :single

    # Search state
    @search_query = nil

    # Search entry widget (to be added to sidebar header)
    @search_entry = Gtk::SearchEntry.new
    @search_entry.placeholder_text = "Search history..."
    @search_entry.signal_connect("search-changed") do
      search(@search_entry.text)
    end

    # Callback invoked when history item is clicked
    # Signature: ->(entry) { ... } where entry responds to #uri
    @on_history_item_selected = nil

    # Set up row activation handler
    @list_widget.signal_connect("row-activated") do |_list, row|
      on_history_item_clicked(row)
    end
  end

  # Sets callback to invoke when history item is selected
  #
  # @param callback [Proc] Callback proc accepting the selected entry: ->(entry) { ... }
  # @return [void]
  def on_history_item_selected=(callback)
    @on_history_item_selected = callback
  end

  # Narrows the list to pages matching the query, or restores recent visits
  #
  # @param query [String] Raw search text; blank restores the recent list
  # @return [void]
  def search(query)
    stripped = query.strip
    @search_query = stripped.empty? ? nil : stripped
    refresh
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
      pages = @callbacks[:get_search_results]&.call(@search_query, limit) || []

      if pages.empty?
        # Show "no results" message
        no_results_label = Gtk::Label.new("No results found for \"#{@search_query}\"")
        no_results_label.margin = 20
        no_results_label.style_context.add_class("dim-label")
        @list_widget.add(no_results_label)
      else
        pages.each do |page|
          # Known wart, preserved: the remove button on a search row passes the
          # *page* id to the delete intent, so it deletes whichever visit happens
          # to share that id. Search rows also carry no favicon, because the
          # search projection does not select one.
          row = create_history_row(page,
                                   timestamp: page.last_visited_at,
                                   delete_id: page.id)
          @list_widget.add(row)
        end
      end
    else
      # Show recent visits
      visits = @callbacks[:get_recent_visits]&.call(limit) || []

      visits.each do |visit|
        row = create_history_row(visit, timestamp: visit.visited_at, delete_id: visit.id)
        @list_widget.add(row)
      end
    end

    @list_widget.show_all
  end

  # Asks for a visit to be forgotten, then redraws
  #
  # @param visit_id [Integer, nil] Visit the user wants gone
  # @return [void]
  def delete_visit(visit_id)
    @callbacks[:on_delete_visit]&.call(visit_id)
    refresh
  end

  private

  # Creates a list box row for a history entry
  #
  # @param entry [Domain::Visit, Domain::Page] Entry to render; handed back to
  #   the selection callback when the row is activated
  # @param timestamp [Time, nil] When the entry was visited
  # @param delete_id [Integer, nil] Visit id the remove button forgets
  # @return [Gtk::ListBoxRow] Configured row widget
  def create_history_row(entry, timestamp:, delete_id:)
    row = Gtk::ListBoxRow.new

    # Horizontal box for favicon + text content
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_top = 8
    hbox.margin_bottom = 8
    hbox.margin_start = 12
    hbox.margin_end = 12

    # Favicon
    favicon_image = @callbacks[:create_favicon_image].call(entry.favicon)
    favicon_image.valign = :start
    hbox.pack_start(favicon_image, expand: false, fill: false, padding: 0)

    # Vertical box for text content
    vbox = Gtk::Box.new(:vertical, 2)

    # Title
    title = entry.display_title.to_s
    title_label = Gtk::Label.new
    title_label.markup = Domain::SidebarTitle.markup(title)
    title_label.halign = :start
    title_label.ellipsize = :end
    vbox.pack_start(title_label, expand: false, fill: false, padding: 0)

    # URL
    url_label = Gtk::Label.new(entry.uri)
    url_label.halign = :start
    url_label.ellipsize = :middle
    url_label.max_width_chars = 40
    url_label.style_context.add_class("dim-label")
    vbox.pack_start(url_label, expand: false, fill: false, padding: 0)

    # Time ago
    time_ago = format_time_ago(timestamp)
    time_label = Gtk::Label.new(time_ago)
    time_label.halign = :start
    time_label.style_context.add_class("dim-label")
    vbox.pack_start(time_label, expand: false, fill: false, padding: 0)

    hbox.pack_start(vbox, expand: true, fill: true, padding: 0)

    # Remove button
    remove_button = Gtk::Button.new(label: "×")
    remove_button.relief = :none
    remove_button.signal_connect("clicked") do
      delete_visit(delete_id)
      true  # Stop event propagation to prevent row-activated signal
    end
    hbox.pack_start(remove_button, expand: false, fill: false, padding: 0)

    row.add(hbox)

    # Store the entry in the row so activation can hand it back
    row.instance_variable_set(:@visit_data, entry)

    row
  end

  # Handles history item click
  #
  # @param row [Gtk::ListBoxRow] Clicked row
  # @return [void]
  def on_history_item_clicked(row)
    entry = row.instance_variable_get(:@visit_data)
    @on_history_item_selected.call(entry) if @on_history_item_selected && entry
  end

  # Formats timestamp as human-readable relative time
  #
  # @param timestamp [Time, nil] When the entry was visited
  # @return [String] Human-readable time string
  def format_time_ago(timestamp)
    seconds_ago = Time.now.to_i - timestamp.to_i
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
