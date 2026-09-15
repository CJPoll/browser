require 'minitest/autorun'
require_relative '../../lib/domain/chrome_visibility'

class DomainChromeVisibilityTest < Minitest::Test
  # The chrome (toolbar + sidebar) hides when EITHER reason to hide is present:
  # zen mode (F11) or a video in Fullscreen API fullscreen. Exhaustive truth
  # table over the two independent inputs.

  def test_visible_when_neither_zen_nor_fullscreen
    refute Domain::ChromeVisibility.hidden?(zen_mode: false, video_fullscreen: false)
  end

  def test_hidden_in_zen_mode_alone
    assert Domain::ChromeVisibility.hidden?(zen_mode: true, video_fullscreen: false)
  end

  def test_hidden_in_video_fullscreen_alone
    assert Domain::ChromeVisibility.hidden?(zen_mode: false, video_fullscreen: true)
  end

  def test_hidden_when_both_zen_and_fullscreen
    # Both reasons overlap: exiting one must not reveal chrome while the other
    # still holds, which is why the predicate ORs them.
    assert Domain::ChromeVisibility.hidden?(zen_mode: true, video_fullscreen: true)
  end
end
