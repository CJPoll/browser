require 'minitest/autorun'
require_relative '../../lib/domain/download'
require_relative '../../lib/domain/download_badge'

class DownloadBadgeTest < Minitest::Test
  CREATED_AT = Time.at(1_700_000_000).freeze

  def build_download(state:)
    Download.new(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      created_at: CREATED_AT,
      state: state
    )
  end

  def test_no_downloads_at_all
    assert_equal :none, Domain::DownloadBadge.state([])
  end

  def test_only_finished_downloads_show_no_badge
    downloads = [
      build_download(state: :completed),
      build_download(state: :failed),
      build_download(state: :cancelled)
    ]

    assert_equal :none, Domain::DownloadBadge.state(downloads)
  end

  def test_running_downloads_show_the_active_badge
    assert_equal :active, Domain::DownloadBadge.state([build_download(state: :pending)])
    assert_equal :active, Domain::DownloadBadge.state([build_download(state: :in_progress)])
  end

  def test_a_paused_download_takes_precedence_over_running_ones
    downloads = [
      build_download(state: :in_progress),
      build_download(state: :paused)
    ]

    assert_equal :paused, Domain::DownloadBadge.state(downloads)
  end

  def test_a_failed_download_never_drives_the_badge
    # Preserved behaviour: the old implementation looked for :failed inside the
    # *active* set, where a failed download can never appear, so the failed
    # badge was unreachable. Pinned here so it is not resurrected by accident.
    downloads = [
      build_download(state: :failed),
      build_download(state: :in_progress)
    ]

    assert_equal :active, Domain::DownloadBadge.state(downloads)
  end

  def test_count_ignores_finished_downloads
    downloads = [
      build_download(state: :pending),
      build_download(state: :paused),
      build_download(state: :completed)
    ]

    assert_equal 2, Domain::DownloadBadge.count(downloads)
  end
end
