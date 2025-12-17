require 'gtk3'

# Window for managing site permissions (popups, media access, certificate exceptions)
class SitePermissionsWindow < Gtk::Window
  # Creates a new site permissions window
  #
  # @param popup_manager [PopupManager] Popup permission manager
  # @param media_permission_manager [MediaPermissionManager] Media permission manager
  # @param certificate_exception_manager [CertificateExceptionManager] Certificate exception manager
  # @param parent_window [Gtk::Window] Parent window for transient relationship
  def initialize(popup_manager, media_permission_manager, certificate_exception_manager, parent_window = nil)
    super(:toplevel)

    @popup_manager = popup_manager
    @media_permission_manager = media_permission_manager
    @certificate_exception_manager = certificate_exception_manager

    set_default_size(600, 500)
    set_title("Site Permissions")
    set_transient_for(parent_window) if parent_window
    set_position(:center)

    # Main container
    vbox = Gtk::Box.new(:vertical, 0)
    add(vbox)

    # Header
    header = Gtk::HeaderBar.new
    header.title = "Site Permissions"
    header.show_close_button = true
    set_titlebar(header)

    # Scrolled window for content
    scrolled = Gtk::ScrolledWindow.new
    scrolled.set_policy(:never, :automatic)
    vbox.pack_start(scrolled, expand: true, fill: true, padding: 0)

    # Content box
    @content_box = Gtk::Box.new(:vertical, 20)
    @content_box.margin = 20
    scrolled.add(@content_box)

    # Popup Permissions section
    create_popup_permissions_section

    # Separator
    separator = Gtk::Separator.new(:horizontal)
    @content_box.pack_start(separator, expand: false, fill: false, padding: 0)

    # Media Permissions section
    create_media_permissions_section

    # Separator
    separator2 = Gtk::Separator.new(:horizontal)
    @content_box.pack_start(separator2, expand: false, fill: false, padding: 0)

    # Certificate Exceptions section
    create_certificate_exceptions_section

    show_all
  end

  private

  # Creates the popup permissions section
  def create_popup_permissions_section
    section_box = Gtk::Box.new(:vertical, 10)
    @content_box.pack_start(section_box, expand: false, fill: false, padding: 0)

    # Section header
    header_label = Gtk::Label.new
    header_label.markup = "<b>Popup Permissions</b>"
    header_label.xalign = 0
    section_box.pack_start(header_label, expand: false, fill: false, padding: 0)

    # Description
    desc_label = Gtk::Label.new("Sites allowed to show popups:")
    desc_label.xalign = 0
    desc_label.style_context.add_class("dim-label")
    section_box.pack_start(desc_label, expand: false, fill: false, padding: 0)

    # List of popup permissions
    @popup_list_box = Gtk::Box.new(:vertical, 5)
    section_box.pack_start(@popup_list_box, expand: false, fill: false, padding: 0)

    refresh_popup_list
  end

  # Creates the media permissions section
  def create_media_permissions_section
    section_box = Gtk::Box.new(:vertical, 10)
    @content_box.pack_start(section_box, expand: false, fill: false, padding: 0)

    # Section header
    header_label = Gtk::Label.new
    header_label.markup = "<b>Media Permissions</b>"
    header_label.xalign = 0
    section_box.pack_start(header_label, expand: false, fill: false, padding: 0)

    # Description
    desc_label = Gtk::Label.new("Sites allowed to access camera/microphone:")
    desc_label.xalign = 0
    desc_label.style_context.add_class("dim-label")
    section_box.pack_start(desc_label, expand: false, fill: false, padding: 0)

    # List of media permissions
    @media_list_box = Gtk::Box.new(:vertical, 5)
    section_box.pack_start(@media_list_box, expand: false, fill: false, padding: 0)

    refresh_media_list
  end

  # Refreshes the popup permissions list
  def refresh_popup_list
    # Clear existing entries
    @popup_list_box.children.each { |child| @popup_list_box.remove(child) }

    # Get all popup exceptions
    exceptions = @popup_manager.all

    if exceptions.empty?
      no_permissions_label = Gtk::Label.new("No sites have popup permissions")
      no_permissions_label.xalign = 0
      no_permissions_label.style_context.add_class("dim-label")
      @popup_list_box.pack_start(no_permissions_label, expand: false, fill: false, padding: 5)
    else
      exceptions.each do |exception|
        row = create_permission_row(exception['host'], -> {
          @popup_manager.block("https://#{exception['host']}")
          refresh_popup_list
        })
        @popup_list_box.pack_start(row, expand: false, fill: false, padding: 0)
      end
    end

    @popup_list_box.show_all
  end

  # Refreshes the media permissions list
  def refresh_media_list
    # Clear existing entries
    @media_list_box.children.each { |child| @media_list_box.remove(child) }

    # Get all media permissions
    permissions = @media_permission_manager.all

    if permissions.empty?
      no_permissions_label = Gtk::Label.new("No sites have media permissions")
      no_permissions_label.xalign = 0
      no_permissions_label.style_context.add_class("dim-label")
      @media_list_box.pack_start(no_permissions_label, expand: false, fill: false, padding: 5)
    else
      permissions.each do |permission|
        permission_text = case permission['permission_type']
                         when 'audio' then '🎤 Audio'
                         when 'video' then '📹 Video'
                         when 'audio_video' then '🎤📹 Audio & Video'
                         else permission['permission_type']
                         end

        label_text = "#{permission['host']} - #{permission_text}"
        row = create_permission_row(label_text, -> {
          @media_permission_manager.revoke("https://#{permission['host']}", permission['permission_type'].to_sym)
          refresh_media_list
        })
        @media_list_box.pack_start(row, expand: false, fill: false, padding: 0)
      end
    end

    @media_list_box.show_all
  end

  # Creates the certificate exceptions section
  def create_certificate_exceptions_section
    section_box = Gtk::Box.new(:vertical, 10)
    @content_box.pack_start(section_box, expand: false, fill: false, padding: 0)

    # Section header
    header_label = Gtk::Label.new
    header_label.markup = "<b>Certificate Exceptions</b>"
    header_label.xalign = 0
    section_box.pack_start(header_label, expand: false, fill: false, padding: 0)

    # Description
    desc_label = Gtk::Label.new("Sites with trusted self-signed/invalid certificates:")
    desc_label.xalign = 0
    desc_label.style_context.add_class("dim-label")
    section_box.pack_start(desc_label, expand: false, fill: false, padding: 0)

    # List of certificate exceptions
    @certificate_list_box = Gtk::Box.new(:vertical, 5)
    section_box.pack_start(@certificate_list_box, expand: false, fill: false, padding: 0)

    refresh_certificate_list
  end

  # Refreshes the certificate exceptions list
  def refresh_certificate_list
    # Clear existing entries
    @certificate_list_box.children.each { |child| @certificate_list_box.remove(child) }

    # Get all certificate exceptions
    exceptions = @certificate_exception_manager.all

    if exceptions.empty?
      no_permissions_label = Gtk::Label.new("No certificate exceptions")
      no_permissions_label.xalign = 0
      no_permissions_label.style_context.add_class("dim-label")
      @certificate_list_box.pack_start(no_permissions_label, expand: false, fill: false, padding: 5)
    else
      exceptions.each do |exception|
        row = create_permission_row(exception['host'], -> {
          @certificate_exception_manager.revoke(exception['host'])
          refresh_certificate_list
        })
        @certificate_list_box.pack_start(row, expand: false, fill: false, padding: 0)
      end
    end

    @certificate_list_box.show_all
  end

  # Creates a permission row with a remove button
  #
  # @param text [String] Label text
  # @param on_remove [Proc] Callback when remove button is clicked
  # @return [Gtk::Box] Row widget
  def create_permission_row(text, on_remove)
    row = Gtk::Box.new(:horizontal, 10)
    row.margin = 5

    # Site label
    label = Gtk::Label.new(text)
    label.xalign = 0
    label.hexpand = true
    row.pack_start(label, expand: true, fill: true, padding: 0)

    # Remove button
    remove_button = Gtk::Button.new(label: "Remove")
    remove_button.signal_connect("clicked") do
      on_remove.call
    end
    row.pack_start(remove_button, expand: false, fill: false, padding: 0)

    row
  end
end
