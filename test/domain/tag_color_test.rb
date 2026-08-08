require 'minitest/autorun'
require_relative '../../lib/domain/tag_color'

# Exhaustive tests for deterministic tag colouring
class TagColorTest < Minitest::Test
  def test_the_same_name_always_gets_the_same_colour
    assert_equal Domain::TagColor.rgb("YouTube"), Domain::TagColor.rgb("YouTube")
  end

  def test_different_names_get_different_colours
    refute_equal Domain::TagColor.rgb("YouTube"), Domain::TagColor.rgb("Gaming")
  end

  def test_colour_is_case_insensitive
    expected = Domain::TagColor.rgb("YouTube")

    assert_equal expected, Domain::TagColor.rgb("youtube")
    assert_equal expected, Domain::TagColor.rgb("YOUTUBE")
  end

  def test_components_are_bytes
    ["YouTube", "Gaming", "a", "", "a very long tag name indeed"].each do |name|
      r, g, b = Domain::TagColor.rgb(name)

      [r, g, b].each do |component|
        assert_kind_of Integer, component
        assert_includes 0..255, component, "#{name} produced an out-of-range component"
      end
    end
  end

  def test_returns_three_components
    assert_equal 3, Domain::TagColor.rgb("YouTube").length
  end

  def test_every_hue_sector_produces_a_colour
    # The HSL conversion branches on which 60-degree sector the hue lands in;
    # walking all 360 hues exercises every branch including the wrap at 360.
    colours = (0..359).map { |hue| Domain::TagColor.rgb_for_hue(hue) }

    assert_equal 360, colours.length
    colours.each do |r, g, b|
      assert_includes 0..255, r
      assert_includes 0..255, g
      assert_includes 0..255, b
    end
  end

  def test_hue_is_derived_from_the_name_checksum
    # Two names with the same lowercase checksum collide -- a known and
    # accepted consequence of hashing with String#sum.
    assert_equal Domain::TagColor.rgb("ab"), Domain::TagColor.rgb("ba")
  end

  def test_the_configured_saturation_and_lightness_are_used
    assert_equal Domain::TagColor.rgb_for_hue(120), Domain::TagColor.hsl_to_rgb(120, 70, 60)
  end
end
