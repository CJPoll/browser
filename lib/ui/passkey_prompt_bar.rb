require 'gtk3'
require 'cgi/escape'

# Consent bar for a passkey request: "this site wants to create a passkey"
# or "sign in with your passkey", with a chooser when several passkeys fit.
#
# Data in (a Domain::PasskeyPrompt), intent out (`on_allow` with the index of
# the chosen passkey, or `on_cancel`). The bar is also the user-presence
# check WebAuthn requires: nothing is signed until a button is pressed.
class PasskeyPromptBar
  attr_reader :widget

  # @param on_allow [Proc] Receives the index of the chosen candidate (0 when
  #   there was nothing to choose)
  # @param on_cancel [Proc] Receives nothing
  def initialize(on_allow:, on_cancel:)
    @on_allow = on_allow
    @on_cancel = on_cancel
    @chooser = nil

    # Use EventBox to allow background color on Box
    @widget = Gtk::EventBox.new

    # Green: distinct from popup yellow, media blue and notification purple
    css_provider = Gtk::CssProvider.new
    css_provider.load(data: <<-CSS)
      .passkey-prompt-bar {
        background-color: #d4edda;
        border-bottom: 1px solid #28a745;
      }
      .passkey-prompt-label {
        color: #155724;
        padding: 8px;
      }
      .passkey-prompt-button {
        margin: 4px;
      }
    CSS
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    @widget.style_context.add_class('passkey-prompt-bar')

    @box = Gtk::Box.new(:horizontal, 8)
    @box.margin = 4
    @widget.add(@box)

    icon = Gtk::Image.new(icon_name: 'dialog-password-symbolic', size: :menu)
    @box.pack_start(icon, expand: false, fill: false, padding: 4)

    @label = Gtk::Label.new
    @label.hexpand = true
    @label.halign = :start
    @label.ellipsize = :end
    @label.style_context.add_class('passkey-prompt-label')
    @box.pack_start(@label, expand: true, fill: true, padding: 0)

    @allow_button = Gtk::Button.new(label: 'Continue')
    @allow_button.style_context.add_class('passkey-prompt-button')
    @allow_button.signal_connect('clicked') { allow }
    @box.pack_end(cancel_button, expand: false, fill: false, padding: 0)
    @box.pack_end(@allow_button, expand: false, fill: false, padding: 0)
  end

  # Renders a prompt
  #
  # @param prompt [Domain::PasskeyPrompt]
  # @return [void]
  def show_prompt(prompt)
    # Pango markup is XML, and the message carries text the page chose.
    @label.markup = "<span foreground='#155724'>#{CGI.escapeHTML(prompt.message)}</span>"
    @allow_button.label = prompt.create? ? 'Create passkey' : 'Sign in'
    show_chooser(prompt.candidate_labels) if prompt.choice_needed?
  end

  # The user agreed; reports which passkey and removes the bar
  #
  # @return [void]
  def allow
    @on_allow&.call(chosen_index)
    destroy
  end

  # The user declined; removes the bar
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

  def cancel_button
    button = Gtk::Button.new(label: 'Cancel')
    button.style_context.add_class('passkey-prompt-button')
    button.signal_connect('clicked') { cancel }
    button
  end

  # @param labels [Array<String>] One per candidate, in candidate order
  def show_chooser(labels)
    @chooser = Gtk::ComboBoxText.new
    labels.each { |label| @chooser.append_text(label) }
    @chooser.active = 0
    @box.pack_end(@chooser, expand: false, fill: false, padding: 0)
  end

  # @return [Integer] Index of the chosen candidate
  def chosen_index
    return 0 unless @chooser

    [@chooser.active, 0].max
  end
end
