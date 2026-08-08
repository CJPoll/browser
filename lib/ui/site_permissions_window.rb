require 'gtk3'

# Window listing the permissions each site has been granted, with a Remove
# button on every row.
#
# Holds no manager, repository or adapter. The Framework passes one descriptor
# per section: where the rows come from (`get_permissions`), what removing one
# means (`on_remove`), and the labels to draw. After emitting a remove intent
# the window redraws that section from its own data source, so it never has to
# know what removal actually did.
class SitePermissionsWindow < Gtk::Window
  # @param sections [Array<Hash>] Section descriptors, in display order:
  #   - :title [String] Section heading
  #   - :description [String] Line under the heading
  #   - :empty_text [String] Shown when the section has no permissions
  #   - :get_permissions [Proc] -> Array<Domain::HostPermission>
  #   - :on_remove [Proc] ->(Domain::HostPermission), optional
  #   - :row_label [Proc] ->(Domain::HostPermission) => String, optional;
  #     defaults to the host
  # @param parent_window [Gtk::Window, nil] Parent for transient relationship
  def initialize(sections:, parent_window: nil)
    super(:toplevel)

    @sections = sections
    @list_boxes = {}

    set_default_size(600, 500)
    set_title("Site Permissions")
    set_transient_for(parent_window) if parent_window
    set_position(:center)

    vbox = Gtk::Box.new(:vertical, 0)
    add(vbox)

    header = Gtk::HeaderBar.new
    header.title = "Site Permissions"
    header.show_close_button = true
    set_titlebar(header)

    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)
    vbox.pack_start(scrolled, expand: true, fill: true, padding: 0)

    @content_box = Gtk::Box.new(:vertical, 20)
    @content_box.margin = 20
    scrolled.add(@content_box)

    @sections.each_with_index do |section, index|
      pack_separator unless index.zero?
      build_section(section)
    end

    show_all
  end

  # Emits a section's remove intent and redraws that section.
  #
  # Public because GTK signal emission does not reach Ruby handlers under
  # minitest here (see lib/ui/CLAUDE.md), so the Remove button's handler is a
  # single call to this method and the behavior is tested through it.
  #
  # @param section [Hash] The section descriptor the row belongs to
  # @param permission [Domain::HostPermission] The row's permission
  # @return [void]
  def remove_permission(section, permission)
    section[:on_remove]&.call(permission)
    refresh_section(section)
  end

  # Redraws one section from its data source.
  #
  # @param section [Hash] Section descriptor
  # @return [void]
  def refresh_section(section)
    list_box = @list_boxes[section.object_id]
    return unless list_box

    list_box.children.each { |child| list_box.remove(child) }

    permissions = section[:get_permissions]&.call || []

    if permissions.empty?
      list_box.pack_start(empty_label(section[:empty_text]), expand: false, fill: false, padding: 5)
    else
      permissions.each do |permission|
        row = permission_row(section, permission)
        list_box.pack_start(row, expand: false, fill: false, padding: 0)
      end
    end

    list_box.show_all
  end

  # Redraws every section.
  #
  # @return [void]
  def refresh
    @sections.each { |section| refresh_section(section) }
  end

  private

  def pack_separator
    separator = Gtk::Separator.new(:horizontal)
    @content_box.pack_start(separator, expand: false, fill: false, padding: 0)
  end

  def build_section(section)
    section_box = Gtk::Box.new(:vertical, 10)
    @content_box.pack_start(section_box, expand: false, fill: false, padding: 0)

    header_label = Gtk::Label.new
    header_label.markup = "<b>#{section[:title]}</b>"
    header_label.xalign = 0
    section_box.pack_start(header_label, expand: false, fill: false, padding: 0)

    desc_label = Gtk::Label.new(section[:description])
    desc_label.xalign = 0
    desc_label.style_context.add_class("dim-label")
    section_box.pack_start(desc_label, expand: false, fill: false, padding: 0)

    list_box = Gtk::Box.new(:vertical, 5)
    section_box.pack_start(list_box, expand: false, fill: false, padding: 0)
    @list_boxes[section.object_id] = list_box

    refresh_section(section)
  end

  def empty_label(text)
    label = Gtk::Label.new(text)
    label.xalign = 0
    label.style_context.add_class("dim-label")
    label
  end

  # Builds a row: the permission's label, and a button that emits the intent
  def permission_row(section, permission)
    row = Gtk::Box.new(:horizontal, 10)
    row.margin = 5

    label = Gtk::Label.new(row_label(section, permission))
    label.xalign = 0
    label.hexpand = true
    row.pack_start(label, expand: true, fill: true, padding: 0)

    remove_button = Gtk::Button.new(label: "Remove")
    remove_button.signal_connect("clicked") do
      remove_permission(section, permission)
    end
    row.pack_start(remove_button, expand: false, fill: false, padding: 0)

    row
  end

  def row_label(section, permission)
    formatter = section[:row_label]
    return formatter.call(permission) if formatter

    permission.host
  end
end
