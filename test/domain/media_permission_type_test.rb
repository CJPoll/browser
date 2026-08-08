require 'minitest/autorun'
require_relative '../../lib/domain/media_permission_type'

class MediaPermissionTypeTest < Minitest::Test
  def test_lists_every_supported_type
    assert_equal %i[audio video audio_video], Domain::MediaPermissionType::ALL
  end

  # --- for ---

  def test_audio_only_request
    assert_equal :audio, Domain::MediaPermissionType.for(audio: true, video: false)
  end

  def test_video_only_request
    assert_equal :video, Domain::MediaPermissionType.for(audio: false, video: true)
  end

  def test_request_for_both_devices
    assert_equal :audio_video, Domain::MediaPermissionType.for(audio: true, video: true)
  end

  # Preserved behavior: the WebKit handler's `else` branch treated a request for
  # neither device as an audio request rather than rejecting it.
  def test_request_for_neither_device_is_treated_as_audio
    assert_equal :audio, Domain::MediaPermissionType.for(audio: false, video: false)
  end

  # --- valid? ---

  def test_recognizes_every_supported_type
    Domain::MediaPermissionType::ALL.each do |type|
      assert Domain::MediaPermissionType.valid?(type), "expected #{type} to be valid"
    end
  end

  def test_accepts_a_type_named_as_a_string
    assert Domain::MediaPermissionType.valid?('video')
  end

  def test_rejects_an_unknown_type
    refute Domain::MediaPermissionType.valid?(:location)
    refute Domain::MediaPermissionType.valid?(nil)
  end

  # --- describe ---

  def test_describes_each_type_for_display
    assert_equal '🎤 Audio', Domain::MediaPermissionType.describe(:audio)
    assert_equal '📹 Video', Domain::MediaPermissionType.describe(:video)
    assert_equal '🎤📹 Audio & Video', Domain::MediaPermissionType.describe(:audio_video)
  end

  def test_describes_a_type_named_as_a_string
    assert_equal '📹 Video', Domain::MediaPermissionType.describe('video')
  end

  # An unrecognized type stored by an older version still has to render.
  def test_an_unknown_type_describes_itself
    assert_equal 'screen', Domain::MediaPermissionType.describe(:screen)
    assert_equal '', Domain::MediaPermissionType.describe(nil)
  end
end
