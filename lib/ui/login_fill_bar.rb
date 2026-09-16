require 'gtk3'
require 'cgi/escape'

# Consent bar for a login fill: a one-row confirm for a single matching login,
# or a dropdown when several match; or a notice when nothing can be filled.
#
# Data in (a Domain::LoginFillPrompt or a Domain::LoginFillNotice), intent out
# (`on_fill` with the chosen candidate index, or `on_cancel`). The bar is the
# user-presence check: nothing is fetched or filled until the Fill button is
# pressed. It never receives a password -- its only inputs are a prompt or a
# notice, neither of which carries one.
#
# Teal, to stand apart from popup yellow, media blue, notification purple and
# passkey green.
class LoginFillBar
  attr_reader :widget

  # @param on_fill [Proc] receives the chosen candidate index (0 when there is
  #   nothing to choose)
  # @param on_cancel [Proc] receives nothing
  def initialize(on_fill:, on_cancel:)
    @on_fill = on_fill
    @on_cancel = on_cancel
    @chooser = nil

    # EventBox so the bar can carry a background colour.
    @widget = Gtk::EventBox.new

    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .login-fill-bar {
        background-color: #d1ecf1;
        border-bottom: 1px solid #17a2b8;
      }
      .login-fill-label {
        color: #0c5460;
        padding: 8px;
      }
      .login-fill-button {
        margin: 4px;
      }
    CSS
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('login-fill-bar')

    @box = Gtk::Box.new(:horizontal, 8)
    @box.margin = 4
    @widget.add(@box)

    icon = Gtk::Image.new(icon_name: 'dialog-password-symbolic', size: :menu)
    @box.pack_start(icon, expand: false, fill: false, padding: 4)

    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.ellipsize = :end
    @label.style_context.add_class('login-fill-label')
    @box.pack_start(@label, expand: true, fill: true, padding: 0)

    @fill_button = Gtk::Button.new(label: 'Fill')
    @fill_button.style_context.add_class('login-fill-button')
    @fill_button.signal_connect('clicked') { fill }

    @cancel_button = Gtk::Button.new(label: 'Cancel')
    @cancel_button.style_context.add_class('login-fill-button')
    @cancel_button.signal_connect('clicked') { cancel }
  end

  # Renders a prompt: the message, a chooser when several accounts match, and
  # the Fill / Cancel buttons.
  #
  # @param prompt [Domain::LoginFillPrompt]
  # @return [void]
  def show_prompt(prompt)
    set_message(prompt.message)
    show_chooser(prompt.candidate_labels) if prompt.choice_needed?
    @box.pack_end(@cancel_button, expand: false, fill: false, padding: 0)
    @box.pack_end(@fill_button, expand: false, fill: false, padding: 0)
  end

  # Renders a notice: the message and a single Dismiss button. There is no Fill
  # button (it is never packed).
  #
  # @param notice [Domain::LoginFillNotice]
  # @return [void]
  def show_notice(notice)
    set_message(notice.message)
    @cancel_button.label = 'Dismiss'
    @box.pack_end(@cancel_button, expand: false, fill: false, padding: 0)
  end

  # The user chose to fill; reports which account and removes the bar.
  #
  # @return [void]
  def fill
    @on_fill&.call(chosen_index)
    destroy
  end

  # The user declined; removes the bar.
  #
  # @return [void]
  def cancel
    @on_cancel&.call
    destroy
  end

  # @return [void]
  def destroy
    @widget.destroy
  end

  private

  def set_message(message)
    # Pango markup is XML, and titles/usernames are the user's data.
    @label.markup = "<span foreground='#0c5460'>#{CGI.escapeHTML(message)}</span>"
  end

  # @param labels [Array<String>] one per candidate, in candidate order
  def show_chooser(labels)
    @chooser = Gtk::ComboBoxText.new
    labels.each { |label| @chooser.append_text(label) }
    @chooser.active = 0
    @box.pack_end(@chooser, expand: false, fill: false, padding: 0)
  end

  # @return [Integer] index of the chosen candidate
  def chosen_index
    return 0 unless @chooser

    [@chooser.active, 0].max
  end
end
