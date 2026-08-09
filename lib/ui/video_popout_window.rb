require 'gtk3'
require 'webkit2-gtk'
require_relative '../domain/video_popout_styles'

# Floating always-on-top window showing a video on its own.
#
# The page is loaded a second time in this window and everything but the
# player is hidden with injected CSS -- WebKitGTK has no Picture-in-Picture
# API to ask for instead (see "Known Limitations" in CLAUDE.md).
class VideoPopoutWindow < Gtk::Window
  DEFAULT_SIZE = [800, 600].freeze

  # @param video_url [String] Page holding the video
  # @param web_context [WebKit2Gtk::WebContext] Shared context, so the popout
  #   is signed in to whatever the tab was
  def initialize(video_url, web_context)
    super()

    set_title('Video Popout')
    set_default_size(*DEFAULT_SIZE)
    set_keep_above(true)

    @webview = WebKit2Gtk::WebView.new(context: web_context)
    @webview.settings.enable_developer_extras = true
    add(@webview)

    @webview.load_uri(video_url)

    @webview.signal_connect('load-changed') do |_webview, load_event|
      hide_everything_but_the_player if load_event == :finished
    end

    signal_connect('key-press-event') { |_widget, event| close_on_escape(event) }

    show_all
  end

  # Hides the surrounding page so only the player is left
  #
  # @return [void]
  def hide_everything_but_the_player
    @webview.run_javascript(Domain::VideoPopoutStyles.injection_script, nil) { |_result| }
  end

  private

  # @param event [Gdk::EventKey] Key press
  # @return [Boolean] True when the key was handled
  def close_on_escape(event)
    return false unless event.keyval == Gdk::Keyval::KEY_Escape

    close
    true
  end
end
