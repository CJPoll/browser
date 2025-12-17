require 'gtk3'

# Notification bar for TLS certificate errors
# Shows at top of web view with option to add security exception
class CertificateExceptionBar
  attr_reader :widget

  # Creates a new certificate exception bar
  #
  # @param on_allow [Proc] Callback when "Add Exception" is clicked, receives host
  # @param on_dismiss [Proc] Callback when "Dismiss" is clicked
  def initialize(on_allow:, on_dismiss:)
    @on_allow = on_allow
    @on_dismiss = on_dismiss
    @current_host = nil
    @current_uri = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Red/orange background for security warning
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .certificate-exception-bar {
        background-color: #f8d7da;
        border-bottom: 1px solid #f5c6cb;
      }
      .certificate-exception-label {
        color: #721c24;
        padding: 8px;
      }
      .certificate-exception-button {
        margin: 4px;
      }
    CSS

    # Add to default screen so CSS works
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('certificate-exception-bar')

    # Inner box for content
    box = Gtk::Box.new(:horizontal, 8)
    box.margin = 4
    @widget.add(box)

    # Warning icon
    warning_label = Gtk::Label.new
    warning_label.markup = "<span foreground='#721c24' size='large'>\u26A0</span>"
    box.pack_start(warning_label, expand: false, fill: false, padding: 4)

    # Message label
    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.style_context.add_class('certificate-exception-label')
    box.pack_start(@label, expand: true, fill: true, padding: 0)

    # Add Exception button
    @allow_button = Gtk::Button.new
    @allow_button.style_context.add_class('certificate-exception-button')
    @allow_button.signal_connect("clicked") do
      @on_allow.call(@current_host, @current_uri) if @current_host && @on_allow
      destroy
    end
    box.pack_start(@allow_button, expand: false, fill: false, padding: 0)

    # Dismiss button
    dismiss_button = Gtk::Button.new(label: "Go Back")
    dismiss_button.style_context.add_class('certificate-exception-button')
    dismiss_button.signal_connect("clicked") do
      @on_dismiss.call if @on_dismiss
      destroy
    end
    box.pack_start(dismiss_button, expand: false, fill: false, padding: 0)
  end

  # Sets the host and URI, updates the UI
  #
  # @param host [String] Host with certificate error
  # @param uri [String] Full URI that failed to load
  # @return [void]
  def set_host(host, uri)
    @current_host = host
    @current_uri = uri
    @label.markup = "<span foreground='#721c24'>Certificate error for <b>#{host}</b> - The site's certificate is not trusted.</span>"
    @allow_button.label = "Add Security Exception"
  end

  # Destroys the notification bar
  #
  # @return [void]
  def destroy
    @widget.destroy
  end
end
