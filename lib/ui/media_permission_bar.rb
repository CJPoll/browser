require 'gtk3'

# Notification bar for media permission requests (camera/microphone)
# Shows at top of web view with allow/deny buttons
class MediaPermissionBar
  attr_reader :widget

  # Creates a new media permission bar
  #
  # @param on_allow [Proc] Callback when "Allow" is clicked, receives (host, permission_type)
  # @param on_deny [Proc] Callback when "Deny" is clicked
  def initialize(on_allow:, on_deny:)
    @on_allow = on_allow
    @on_deny = on_deny
    @current_host = nil
    @permission_type = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Blue background via CSS (distinct from popup yellow)
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .media-permission-bar {
        background-color: #cce5ff;
        border-bottom: 1px solid #004085;
      }
      .media-permission-label {
        color: #004085;
        padding: 8px;
      }
      .media-permission-button {
        margin: 4px;
      }
    CSS

    # Add to default screen so CSS works
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('media-permission-bar')

    # Inner box for content
    box = Gtk::Box.new(:horizontal, 8)
    box.margin = 4
    @widget.add(box)

    # Message label
    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.style_context.add_class('media-permission-label')
    box.pack_start(@label, expand: true, fill: true, padding: 0)

    # Allow button
    @allow_button = Gtk::Button.new
    @allow_button.style_context.add_class('media-permission-button')
    @allow_button.signal_connect("clicked") do
      @on_allow.call(@current_host, @permission_type) if @current_host && @on_allow
      destroy
    end
    box.pack_start(@allow_button, expand: false, fill: false, padding: 0)

    # Deny button
    deny_button = Gtk::Button.new(label: "Deny")
    deny_button.style_context.add_class('media-permission-button')
    deny_button.signal_connect("clicked") do
      @on_deny.call if @on_deny
      destroy
    end
    box.pack_start(deny_button, expand: false, fill: false, padding: 0)
  end

  # Sets the host and permission type, updates the UI
  #
  # @param host [String] Host requesting permission
  # @param permission_type [Symbol] :audio, :video, or :audio_video
  # @return [void]
  def set_request(host, permission_type)
    @current_host = host
    @permission_type = permission_type

    device_name = case permission_type
                  when :audio then "microphone"
                  when :video then "camera"
                  when :audio_video then "camera and microphone"
                  else "media devices"
                  end

    @label.markup = "<span foreground='#004085'>#{host} wants to use your #{device_name}</span>"
    @allow_button.label = "Allow"
  end

  # Destroys the notification bar
  #
  # @return [void]
  def destroy
    @widget.destroy
  end
end
