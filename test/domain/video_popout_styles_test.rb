require_relative '../test_helper'
require_relative '../../lib/domain/video_popout_styles'

# Tests for Domain::VideoPopoutStyles - the payload the popout injects
class VideoPopoutStylesTest < Minitest::Test
  def test_css_hides_the_youtube_chrome
    css = Domain::VideoPopoutStyles.css

    ['#masthead-container', '#related', '#secondary', '#comments', '#below', '#meta', '#info'].each do |selector|
      assert_includes css, "#{selector} { display: none !important; }"
    end
  end

  def test_css_stretches_the_player_over_the_whole_window
    css = Domain::VideoPopoutStyles.css

    assert_includes css, '#movie_player'
    assert_includes css, 'width: 100vw !important;'
    assert_includes css, 'height: 100vh !important;'
  end

  def test_the_script_carries_the_stylesheet
    assert_includes Domain::VideoPopoutStyles.injection_script, '#masthead-container'
  end

  def test_the_script_appends_a_style_element
    script = Domain::VideoPopoutStyles.injection_script

    assert_includes script, "document.createElement('style')"
    assert_includes script, 'document.head.appendChild(style)'
  end

  def test_the_script_asks_the_player_for_theater_mode
    assert_includes Domain::VideoPopoutStyles.injection_script, '.ytp-size-button'
  end

  # The CSS is interpolated into a JavaScript template literal, so an
  # unescaped backtick would end the literal early.
  def test_the_script_escapes_backticks_from_the_stylesheet
    refute_includes Domain::VideoPopoutStyles.css, '`'

    script = Domain::VideoPopoutStyles.injection_script
    backticks = script.scan(/(?<!\\)`/)

    assert_equal 2, backticks.size, 'only the template literal delimiters should be unescaped'
  end

  def test_the_script_is_an_immediately_invoked_function
    script = Domain::VideoPopoutStyles.injection_script.strip

    assert script.start_with?('(function() {'), 'expected an IIFE'
    assert script.end_with?('})();'), 'expected an IIFE'
  end
end
