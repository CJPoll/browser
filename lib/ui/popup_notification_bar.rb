require 'gtk3'

# Notification bar for blocked popups
# Shows at top of web view with allow/block buttons
class PopupNotificationBar
  attr_reader :widget

  # Creates a new popup notification bar
  #
  # @param on_allow [Proc] Callback when "Allow" is clicked, receives host
  # @param on_dismiss [Proc] Callback when "Block" is clicked
  def initialize(on_allow:, on_dismiss:)
    @on_allow = on_allow
    @on_dismiss = on_dismiss
    @current_host = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Yellow background via CSS
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .popup-notification-bar {
        background-color: #fff3cd;
        border-bottom: 1px solid #ffc107;
      }
      .popup-notification-label {
        color: #856404;
        padding: 8px;
      }
      .popup-notification-button {
        margin: 4px;
      }
    CSS

    # Add to default screen so CSS works
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('popup-notification-bar')

    # Inner box for content
    box = Gtk::Box.new(:horizontal, 8)
    box.margin = 4
    @widget.add(box)

    # Message label
    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.style_context.add_class('popup-notification-label')
    box.pack_start(@label, expand: true, fill: true, padding: 0)

    # Allow button
    @allow_button = Gtk::Button.new
    @allow_button.style_context.add_class('popup-notification-button')
    @allow_button.signal_connect("clicked") do
      @on_allow.call(@current_host) if @current_host && @on_allow
      destroy
    end
    box.pack_start(@allow_button, expand: false, fill: false, padding: 0)

    # Dismiss button
    dismiss_button = Gtk::Button.new(label: "Dismiss")
    dismiss_button.style_context.add_class('popup-notification-button')
    dismiss_button.signal_connect("clicked") do
      @on_dismiss.call if @on_dismiss
      destroy
    end
    box.pack_start(dismiss_button, expand: false, fill: false, padding: 0)

  end

  # Sets the host and updates the UI
  #
  # @param host [String] Host that was blocked
  # @return [void]
  def set_host(host)
    @current_host = host
    # Use Pango markup for reliable text color
    @label.markup = "<span foreground='#856404'>Popup blocked from #{host}</span>"
    @allow_button.label = "Allow popups for #{host}"
  end

  # Destroys the notification bar
  #
  # @return [void]
  def destroy
    @widget.destroy
  end
end
