require 'gtk3'
require 'webkit2-gtk'

class VideoPopoutWindow < Gtk::Window
  def initialize(video_url, web_context)
    super()

    set_title("Video Popout")
    set_default_size(800, 600)
    set_keep_above(true)  # Always on top

    # Create webview with the same context (shares cookies/session)
    @webview = WebKit2Gtk::WebView.new(context: web_context)

    # Enable developer extras (in case we need to debug)
    settings = @webview.settings
    settings.enable_developer_extras = true

    # Add webview to window
    add(@webview)

    # Load the video URL
    @webview.load_uri(video_url)

    # Inject CSS to hide everything except the video player
    @webview.signal_connect("load-changed") do |_webview, load_event|
      if load_event == :finished
        inject_youtube_css
      end
    end

    # Close window when Escape is pressed
    signal_connect("key-press-event") do |widget, event|
      if event.keyval == Gdk::Keyval::KEY_Escape
        close
        true
      else
        false
      end
    end

    show_all
  end

  def inject_youtube_css
    # CSS to hide everything except the video player on YouTube
    css = <<-CSS
      /* Hide YouTube header */
      #masthead-container { display: none !important; }

      /* Hide sidebar/recommendations */
      #related { display: none !important; }
      #secondary { display: none !important; }

      /* Hide comments */
      #comments { display: none !important; }

      /* Hide video info below player */
      #below { display: none !important; }

      /* Hide description, etc */
      #meta { display: none !important; }
      #info { display: none !important; }

      /* Make the page background dark */
      ytd-watch-flexy { background: #000 !important; }

      /* Center and maximize the video player */
      #player-container-outer,
      #player-container-inner,
      #player-container,
      #movie_player {
        position: fixed !important;
        top: 0 !important;
        left: 0 !important;
        width: 100vw !important;
        height: 100vh !important;
        max-width: 100vw !important;
        max-height: 100vh !important;
        margin: 0 !important;
        padding: 0 !important;
      }

      /* Hide everything else */
      #page-manager {
        display: flex !important;
        align-items: center !important;
        justify-content: center !important;
        background: #000 !important;
      }
    CSS

    # Inject the CSS
    js = <<-JS
      (function() {
        var style = document.createElement('style');
        style.textContent = `#{css.gsub('`', '\`')}`;
        document.head.appendChild(style);

        // Try to enter theater mode if not already
        var player = document.querySelector('.html5-video-player');
        if (player && !player.classList.contains('ytp-large-width-mode')) {
          var theaterButton = document.querySelector('.ytp-size-button');
          if (theaterButton) {
            theaterButton.click();
          }
        }
      })();
    JS

    @webview.run_javascript(js, nil) do |result|
      # Ignore result, just inject the CSS
    end
  end
end
