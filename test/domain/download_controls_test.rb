require 'minitest/autorun'
require_relative '../../lib/domain/download'
require_relative '../../lib/domain/download_controls'

class DownloadControlsTest < Minitest::Test
  CREATED_AT = Time.at(1_700_000_000).freeze

  def build_download(state)
    Download.new(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      created_at: CREATED_AT,
      state: state
    )
  end

  def intents_for(state)
    Domain::DownloadControls.for(build_download(state)).map { |control| control[:intent] }
  end

  def test_a_running_download_can_be_paused_or_cancelled
    assert_equal [:pause, :cancel], intents_for(:pending)
    assert_equal [:pause, :cancel], intents_for(:in_progress)
  end

  def test_a_paused_download_can_be_resumed_or_cancelled
    assert_equal [:resume, :cancel], intents_for(:paused)
  end

  def test_a_failed_download_can_be_retried_or_removed
    # Retry is the same intent as resume: a fresh transfer to the same
    # destination. Only the wording differs.
    assert_equal [:resume, :remove], intents_for(:failed)
  end

  def test_a_completed_download_can_be_revealed_or_removed
    assert_equal [:open_location, :remove], intents_for(:completed)
  end

  def test_a_cancelled_download_can_only_be_removed
    assert_equal [:remove], intents_for(:cancelled)
  end

  def test_every_state_offers_at_least_one_control
    Download::STATES.each do |state|
      refute_empty intents_for(state), "#{state} offers no control"
    end
  end

  def test_controls_that_change_state_match_the_downloads_own_predicates
    # The offered controls and the transitions the domain will actually allow
    # must not drift apart.
    Download::STATES.each do |state|
      download = build_download(state)
      intents = intents_for(state)

      assert_equal download.can_pause?, intents.include?(:pause), "pause mismatch for #{state}"
      assert_equal download.can_resume?, intents.include?(:resume), "resume mismatch for #{state}"
      assert_equal download.can_cancel?, intents.include?(:cancel), "cancel mismatch for #{state}"
    end
  end

  def test_descriptors_carry_a_label_and_tooltip
    control = Domain::DownloadControls.for(build_download(:paused)).first

    assert_equal '▶', control[:label]
    assert_equal 'Resume (re-downloads)', control[:tooltip]
  end
end
