# frozen_string_literal: true

module Domain
  # The camera/microphone permissions a site can be granted.
  #
  # A single request may name either device or both, so the three types are not
  # independent flags -- `:audio_video` is its own grant and does not imply the
  # other two.
  module MediaPermissionType
    AUDIO = :audio
    VIDEO = :video
    AUDIO_VIDEO = :audio_video

    ALL = [AUDIO, VIDEO, AUDIO_VIDEO].freeze

    DESCRIPTIONS = {
      AUDIO => '🎤 Audio',
      VIDEO => '📹 Video',
      AUDIO_VIDEO => '🎤📹 Audio & Video'
    }.freeze

    # Derives the permission type a device request asks for
    #
    # A request naming neither device is treated as audio, preserving the
    # browser's long-standing fall-through behavior.
    #
    # @param audio [Boolean] Request names an audio device
    # @param video [Boolean] Request names a video device
    # @return [Symbol] One of ALL
    def self.for(audio:, video:)
      return AUDIO_VIDEO if audio && video
      return VIDEO if video

      AUDIO
    end

    # @param type [Symbol, String, nil] Candidate type
    # @return [Boolean] True if the type is one this browser grants
    def self.valid?(type)
      return false unless type

      ALL.include?(type.to_sym)
    end

    # Human-readable description for display
    #
    # A type this version does not recognise -- a record left by another
    # version -- describes itself rather than vanishing from the list.
    #
    # @param type [Symbol, String, nil] Permission type
    # @return [String] Description
    def self.describe(type)
      DESCRIPTIONS[type&.to_sym] || type.to_s
    end
  end
end
