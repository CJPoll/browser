require 'gtk3'

# Notification bar for web notification permission requests
# Shows at top of web view with allow/deny buttons
class NotificationPermissionBar
  attr_reader :widget

  # Creates a new notification permission bar
  #
  # @param on_allow [Proc] Callback when "Allow" is clicked, receives (host)
  # @param on_deny [Proc] Callback when "Deny" is clicked
  def initialize(on_allow:, on_deny:)
    @on_allow = on_allow
    @on_deny = on_deny
    @current_host = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Purple background (distinct from popup yellow and media blue)
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .notification-permission-bar {
        background-color: #e2d5f0;
        border-bottom: 1px solid #6f42c1;
      }
      .notification-permission-label {
        color: #4a2c7c;
        padding: 8px;
      }
      .notification-permission-button {
        margin: 4px;
      }
    CSS

    # Add to default screen so CSS works
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('notification-permission-bar')

    # Inner box for content
    box = Gtk::Box.new(:horizontal, 8)
    box.margin = 4
    @widget.add(box)

    # Bell icon
    icon = Gtk::Image.new(icon_name: "notification-symbolic", size: :menu)
    box.pack_start(icon, expand: false, fill: false, padding: 4)

    # Message label
    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.style_context.add_class('notification-permission-label')
    box.pack_start(@label, expand: true, fill: true, padding: 0)

    # Allow button
    @allow_button = Gtk::Button.new(label: "Allow")
    @allow_button.style_context.add_class('notification-permission-button')
    @allow_button.signal_connect("clicked") do
      @on_allow.call(@current_host) if @current_host && @on_allow
      destroy
    end
    box.pack_start(@allow_button, expand: false, fill: false, padding: 0)

    # Deny button
    deny_button = Gtk::Button.new(label: "Block")
    deny_button.style_context.add_class('notification-permission-button')
    deny_button.signal_connect("clicked") do
      @on_deny.call if @on_deny
      destroy
    end
    box.pack_start(deny_button, expand: false, fill: false, padding: 0)
  end

  # Sets the host requesting permission, updates the UI
  #
  # @param host [String] Host requesting notification permission
  # @return [void]
  def set_host(host)
    @current_host = host
    @label.markup = "<span foreground='#4a2c7c'>#{host} wants to send you notifications</span>"
  end

  # Destroys the notification bar
  #
  # @return [void]
  def destroy
    @widget.destroy
  end
end
