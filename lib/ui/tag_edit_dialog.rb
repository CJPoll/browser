require 'gtk3'
require 'cgi'

# Dialog for editing tags assigned to a queue entry
#
# Holds no manager, repository or adapter. The tag list arrives through `get_*`
# callbacks and each toggle reports intent through an `on_*` callback that
# hands back the manager's result symbol; the Framework (`BrowserWindow`) binds
# them to `Managers::QueueManager`.
class TagEditDialog
  attr_reader :dialog

  # Creates a new tag edit dialog
  #
  # @param parent_window [Gtk::Window] Parent window for modal dialog
  # @param entry [Domain::QueueEntry] Queue entry being tagged
  # @param callbacks [Hash] Data sources and intents:
  #   - :get_all_tags => -> { Array<Domain::Tag> } alphabetical
  #   - :get_assigned_tag_ids => ->(entry_id) { Array<Integer> }
  #   - :on_assign_tag => ->(entry_id, tag_id) { Symbol result }
  #   - :on_unassign_tag => ->(entry_id, tag_id) { Symbol result }
  #   - :on_create_tag => ->(tag_name) { Domain::Tag, nil }
  #   - :on_tags_changed => -> { ... } invoked after tags change
  #   - :on_error => ->(message) { ... }; when absent, a modal
  #     Gtk::MessageDialog is shown instead
  def initialize(parent_window, entry, callbacks = {})
    @parent_window = parent_window
    @entry = entry
    @callbacks = callbacks
    @on_tags_changed = callbacks[:on_tags_changed]
    @on_error = callbacks[:on_error]

    # Current assigned tag IDs (for tracking changes)
    @assigned_tag_ids = Array(callbacks[:get_assigned_tag_ids]&.call(@entry.id))

    # Build dialog
    create_dialog
    create_search_box
    create_tag_checklist
    create_new_tag_section
  end

  # Shows the dialog (modal)
  def show
    @dialog.show_all
    @dialog.run
    @dialog.destroy
  end

  # Assigns or unassigns a tag, following the result the Framework reports back
  #
  # `:already_assigned` and `:not_assigned` are not errors -- the checkbox is
  # already showing what the user asked for -- so they are silently ignored.
  #
  # @param tag [Domain::Tag] Tag the user ticked or unticked
  # @param assign [Boolean] True when the checkbox was ticked
  # @return [void]
  def toggle_tag(tag, assign)
    intent = assign ? :on_assign_tag : :on_unassign_tag
    result = @callbacks[intent]&.call(@entry.id, tag.id)

    case result
    when :assigned
      @assigned_tag_ids << tag.id
      notify_tags_changed
    when :unassigned
      @assigned_tag_ids.delete(tag.id)
      notify_tags_changed
    when :invalid_entry
      report_missing_entry
    end
  end

  private

  # The entry was deleted while the dialog was open: say so and close, since
  # nothing else in the dialog can succeed.
  def report_missing_entry
    show_error_dialog("Queue entry no longer exists")
    @dialog.response(Gtk::ResponseType::CLOSE)
  end

  def create_dialog
    title = @entry.display_title

    # Truncate title to exactly 50 chars
    if title.length > 50
      title = title[0...50] + "..."  # [0...50] = chars 0-49, + "..." = 53 total
    end

    # Escape HTML entities
    title = CGI.escapeHTML(title)

    @dialog = Gtk::Dialog.new(
      title: "Edit Tags for \"#{title}\"",
      parent: @parent_window,
      flags: :modal
    )

    @dialog.set_default_size(500, 600)
    @dialog.resizable = false

    # Add Close button
    @dialog.add_button("Close", :close)

    # Content area
    @content_area = @dialog.child
  end

  def create_search_box
    # Search box with label
    search_label = Gtk::Label.new("Search tags:")
    search_label.halign = :start
    search_label.margin_top = 12
    search_label.margin_start = 12
    search_label.margin_end = 12
    @content_area.pack_start(search_label, expand: false, fill: false, padding: 0)

    # Search entry
    @search_entry = Gtk::Entry.new
    @search_entry.placeholder_text = "Type to filter..."
    @search_entry.margin_start = 12
    @search_entry.margin_end = 12
    @search_entry.margin_bottom = 8
    @content_area.pack_start(@search_entry, expand: false, fill: false, padding: 0)

    # Connect search handler
    @search_entry.signal_connect("changed") do
      filter_tag_list(@search_entry.text)
    end
  end

  def create_tag_checklist
    # Scrolled window for tag list
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)
    scrolled.margin_start = 12
    scrolled.margin_end = 12
    scrolled.vexpand = true
    @content_area.pack_start(scrolled, expand: true, fill: true, padding: 0)

    # ListBox for checkboxes
    @tag_list_box = Gtk::ListBox.new
    @tag_list_box.selection_mode = :none  # No row selection, only checkbox interaction
    scrolled.add(@tag_list_box)

    # Populate with all tags
    populate_tag_list

    # Ensure rows are visible (needed for tests that don't call show())
    @tag_list_box.show_all
  end

  def populate_tag_list
    # Get all tags sorted alphabetically
    all_tags = @callbacks[:get_all_tags]&.call || []

    all_tags.each do |tag|
      row = create_tag_checkbox_row(tag)
      @tag_list_box.add(row)
    end
  end

  def create_tag_checkbox_row(tag)
    row = Gtk::ListBoxRow.new

    # Checkbox with tag name
    checkbox = Gtk::CheckButton.new
    checkbox.label = tag.name
    checkbox.margin_top = 6
    checkbox.margin_bottom = 6
    checkbox.margin_start = 12
    checkbox.margin_end = 12

    # Check if tag is assigned
    checkbox.active = @assigned_tag_ids.include?(tag.id)

    # Immediate assignment/unassignment on toggle
    checkbox.signal_connect("toggled") do
      toggle_tag(tag, checkbox.active?)
    end

    row.add(checkbox)

    # Store tag for filtering
    row.instance_variable_set(:@tag, tag)
    row.instance_variable_set(:@checkbox, checkbox)
    row.instance_variable_set(:@filter_visible, true)  # Track visibility for tests

    # Show the row and checkbox
    checkbox.show
    row.show

    row
  end

  # Filters tag list based on search text
  # Search filtering behavior:
  # - Case-insensitive substring matching
  # - Strips whitespace before filtering
  # - Empty/whitespace-only search shows all tags
  def filter_tag_list(search_text)
    search_text = search_text.strip.downcase

    @tag_list_box.children.each do |row|
      tag = row.instance_variable_get(:@tag)
      should_show = search_text.empty? || tag.name.downcase.include?(search_text)
      if should_show
        row.show
        row.instance_variable_set(:@filter_visible, true)
      else
        row.hide
        row.instance_variable_set(:@filter_visible, false)
      end
    end
  end

  def create_new_tag_section
    # Separator
    separator = Gtk::Separator.new(:horizontal)
    separator.margin_top = 12
    separator.margin_bottom = 12
    @content_area.pack_start(separator, expand: false, fill: false, padding: 0)

    # Label
    label = Gtk::Label.new("Create new tag:")
    label.halign = :start
    label.margin_start = 12
    label.margin_end = 12
    @content_area.pack_start(label, expand: false, fill: false, padding: 0)

    # Horizontal box for entry + button
    hbox = Gtk::Box.new(:horizontal, 8)
    hbox.margin_start = 12
    hbox.margin_end = 12
    hbox.margin_bottom = 12
    @content_area.pack_start(hbox, expand: false, fill: false, padding: 0)

    # Entry for new tag name
    @new_tag_entry = Gtk::Entry.new
    @new_tag_entry.placeholder_text = "Tag name..."
    @new_tag_entry.hexpand = true
    hbox.pack_start(@new_tag_entry, expand: true, fill: true, padding: 0)

    # Create button
    create_button = Gtk::Button.new(label: "Create & Assign")
    hbox.pack_start(create_button, expand: false, fill: false, padding: 0)

    # Create and assign tag
    create_button.signal_connect("clicked") do
      create_and_assign_tag
    end

    # Enter key in new tag entry also creates tag
    @new_tag_entry.signal_connect("activate") do
      create_and_assign_tag
    end
  end

  # Handles creating and assigning new tag
  # Tag assignment edge cases:
  # - Empty/whitespace-only name: silently ignored (no error shown)
  # - Duplicate tag name: scrolls to existing checkbox, clears entry
  # - Invalid entry ID: shows error dialog "Queue entry no longer exists"
  # - Search filter active: refreshes list and reapplies filter (new tag may be hidden)
  def create_and_assign_tag
    tag_name = @new_tag_entry.text.strip
    return if tag_name.empty?  # Silent no-op for empty input

    # Create or find tag
    new_tag = @callbacks[:on_create_tag]&.call(tag_name)
    if new_tag.nil?
      # Invalid tag name (too long, whitespace-only, etc.)
      show_error_dialog("Invalid tag name")
      return
    end

    # Assign to entry
    result = @callbacks[:on_assign_tag]&.call(@entry.id, new_tag.id)

    case result
    when :assigned
      @assigned_tag_ids << new_tag.id
      @new_tag_entry.text = ""
      refresh_tag_list  # Reapplies search filter
      notify_tags_changed
    when :already_assigned
      # Tag already assigned - just clear entry and scroll to existing checkbox
      @new_tag_entry.text = ""
      # Find and scroll to existing checkbox (no flash effect - visual feedback from scrolling)
      @tag_list_box.children.each do |row|
        tag = row.instance_variable_get(:@tag)
        if tag.id == new_tag.id
          # Scroll to row to show user the tag is already assigned
          @tag_list_box.select_row(row)
          break
        end
      end
    when :invalid_entry
      # Entry was deleted
      report_missing_entry
    else
      # Unexpected error
      show_error_dialog("Failed to assign tag: #{result}")
    end
  end

  # Refreshes tag list (rebuilds all rows)
  # Reapplies active search filter after refresh
  def refresh_tag_list
    # Clear existing rows
    @tag_list_box.children.each { |child| @tag_list_box.remove(child) }

    # Repopulate
    populate_tag_list

    # Reapply search filter if active
    # Check stripped length to handle whitespace-only search text
    filter_tag_list(@search_entry.text) if @search_entry.text.strip.length > 0
  end

  def notify_tags_changed
    @on_tags_changed.call if @on_tags_changed
  end

  # Shows error dialog
  # Error dialog hierarchy:
  # - BrowserWindow (main window)
  #   - TagEditDialog (modal to BrowserWindow)
  #     - Error MessageDialog (modal to TagEditDialog)
  # This is the intended hierarchy - error dialogs are parented to TagEditDialog
  # so they appear centered on the tag dialog, not the main window
  def show_error_dialog(message)
    if @on_error
      @on_error.call(message)
      return
    end

    error_dialog = Gtk::MessageDialog.new(
      parent: @dialog,  # Parent to TagEditDialog, not BrowserWindow
      flags: :modal,
      type: :error,
      buttons: :ok,
      message: message
    )
    error_dialog.run
    error_dialog.destroy
  end
end
