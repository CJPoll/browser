# frozen_string_literal: true

module Domain
  # The colour a tag is drawn in.
  #
  # A tag has no stored colour: the name determines it, so the same tag looks
  # the same in the queue row, the filter bar and anywhere else it appears
  # without anything having to be persisted or passed around. The name's
  # checksum picks a hue; saturation and lightness are fixed so every tag is
  # equally vivid and white text stays readable on top of it.
  #
  # Names that share a lowercase checksum share a colour ("ab" and "ba"). That
  # collision is accepted -- the colour is a visual aid, not an identifier.
  module TagColor
    # Percentage saturation -- vivid enough to tell pills apart
    SATURATION = 70

    # Percentage lightness -- dark enough for white text to read against
    LIGHTNESS = 60

    # Number of distinct hues
    HUE_RANGE = 360

    # The colour for a tag name
    #
    # @param tag_name [String] Tag name, matched case-insensitively
    # @return [Array<Integer>] `[r, g, b]`, each 0-255
    def self.rgb(tag_name)
      rgb_for_hue(hue_for(tag_name))
    end

    # The hue a tag name maps to
    #
    # @param tag_name [String] Tag name, matched case-insensitively
    # @return [Integer] Hue in degrees (0-359)
    def self.hue_for(tag_name)
      tag_name.downcase.sum % HUE_RANGE
    end

    # The colour for a hue at the configured saturation and lightness
    #
    # @param hue [Integer] Hue in degrees (0-360)
    # @return [Array<Integer>] `[r, g, b]`, each 0-255
    def self.rgb_for_hue(hue)
      hsl_to_rgb(hue, SATURATION, LIGHTNESS)
    end

    # Converts HSL to RGB
    #
    # Formula from https://en.wikipedia.org/wiki/HSL_and_HSV#HSL_to_RGB
    #
    # @param hue [Integer] Hue in degrees (0-360)
    # @param saturation [Integer] Saturation percentage (0-100)
    # @param lightness [Integer] Lightness percentage (0-100)
    # @return [Array<Integer>] `[r, g, b]`, each 0-255
    def self.hsl_to_rgb(hue, saturation, lightness)
      c = (1 - (2 * lightness / 100.0 - 1).abs) * (saturation / 100.0)
      h_prime = hue / 60.0
      x = c * (1 - (h_prime % 2 - 1).abs)

      r1, g1, b1 = case h_prime.floor
                   when 0 then [c, x, 0]
                   when 1 then [x, c, 0]
                   when 2 then [0, c, x]
                   when 3 then [0, x, c]
                   when 4 then [x, 0, c]
                   when 5 then [c, 0, x]
                   else [0, 0, 0]
                   end

      m = lightness / 100.0 - c / 2.0

      [
        ((r1 + m) * 255).round,
        ((g1 + m) * 255).round,
        ((b1 + m) * 255).round
      ]
    end
  end
end
