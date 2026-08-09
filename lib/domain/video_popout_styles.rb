# frozen_string_literal: true

module Domain
  # The payload the video popout window injects into a YouTube page to leave
  # nothing on screen but the player.
  #
  # Deterministic content behind a method, following the
  # Domain::MarkdownStyles / Domain::ArticleExtractorJS precedent: producing
  # it reads nothing, so it is Domain rather than a file an adapter loads.
  module VideoPopoutStyles
    # Hides YouTube's chrome and stretches the player over the whole window
    #
    # @return [String] CSS
    def self.css
      <<~CSS
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
    end

    # Adds the stylesheet to the page and asks the player for theater mode
    #
    # The CSS travels inside a JavaScript template literal, so any backtick in
    # it is escaped -- otherwise the stylesheet would end the literal and the
    # rest of the script would be parsed as JavaScript.
    #
    # @return [String] JavaScript to run in the page
    def self.injection_script
      <<~JS
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
    end
  end
end
