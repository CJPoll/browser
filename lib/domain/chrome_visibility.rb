module Domain
  # Whether the browser chrome (toolbar + sidebar) should be hidden right now.
  #
  # Two independent reasons hide the chrome -- zen mode (F11) and a video that
  # has entered Fullscreen API fullscreen -- and they can overlap. Both funnel
  # through this one predicate so the overlap composes correctly: exiting video
  # fullscreen while still in zen mode must NOT reveal the chrome, and vice
  # versa. The chrome is hidden while either reason holds.
  module ChromeVisibility
    module_function

    def hidden?(zen_mode:, video_fullscreen:)
      zen_mode || video_fullscreen
    end
  end
end
