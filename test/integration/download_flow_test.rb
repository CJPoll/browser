require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require_relative '../../lib/domain/download'
require_relative '../../lib/repositories/download_repository'
require_relative '../../lib/managers/download_coordinator'

# Integration test for the download flow without mocks
# Tests: Repository <-> Coordinator <-> Download domain <-> real filesystem
class DownloadFlowTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['downloads', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    # A directory of our own: conflict resolution consults the real
    # filesystem, so the test must not depend on what is lying around in /tmp.
    @download_dir = Dir.mktmpdir('toy-browser-downloads')

    @repository = Repositories::DownloadRepository.new(db_path: @temp_db_path)
    @coordinator = DownloadCoordinator.new(@repository)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@temp_db_path)
    FileUtils.remove_entry(@download_dir) if @download_dir && Dir.exist?(@download_dir)
  end

  # Path inside this test's own download directory
  def download_path(filename)
    File.join(@download_dir, filename)
  end

  def test_happy_path_download_start_to_completion
    # 1. Start a download
    url = 'https://example.com/file.pdf'
    destination = download_path('test_download.pdf')

    download = @coordinator.start_download(url, destination)

    assert_equal :pending, download.state
    refute_nil download.id
    assert_equal url, download.url
    assert_equal destination, download.destination

    # 2. Update progress (simulating WebKit progress callbacks)
    download = @coordinator.update_progress(download.id, bytes_received: 500, total_bytes: 1000)

    assert_equal :in_progress, download.state
    assert_equal 500, download.bytes_received
    assert_equal 1000, download.total_bytes
    assert_equal 50.0, download.progress_percentage

    # 3. More progress
    download = @coordinator.update_progress(download.id, bytes_received: 1000, total_bytes: 1000)

    assert_equal 1000, download.bytes_received
    assert_equal 100.0, download.progress_percentage

    # 4. Mark completed
    download = @coordinator.mark_completed(download.id)

    assert_equal :completed, download.state
    refute_nil download.completed_at

    # 5. Verify persisted correctly
    persisted = @repository.find_by_id(download.id)

    assert_equal :completed, persisted.state
    assert_equal url, persisted.url
    assert_equal destination, persisted.destination
  end

  def test_download_failure_flow
    download = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    @coordinator.update_progress(download.id, bytes_received: 100, total_bytes: 1000)

    # Simulate failure
    failed = @coordinator.mark_failed(download.id, 'Connection timeout')

    assert_equal :failed, failed.state
    assert_equal 'Connection timeout', failed.error_message
    refute_nil failed.completed_at

    # Verify persisted
    persisted = @repository.find_by_id(download.id)
    assert_equal :failed, persisted.state
    assert_equal 'Connection timeout', persisted.error_message
  end

  def test_download_cancellation_flow
    download = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    @coordinator.update_progress(download.id, bytes_received: 500, total_bytes: 1000)

    # User cancels
    cancelled = @coordinator.cancel_download(download.id)

    assert_equal :cancelled, cancelled.state
    refute_nil cancelled.completed_at

    # Verify persisted
    persisted = @repository.find_by_id(download.id)
    assert_equal :cancelled, persisted.state
  end

  def test_filename_conflict_resolution
    # Create two downloads with same destination
    download1 = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    download2 = @coordinator.start_download('https://example.com/other/file.pdf', download_path('file.pdf'))

    # Second download should have resolved filename
    assert_equal download_path('file.pdf'), download1.destination
    assert_equal download_path('file (1).pdf'), download2.destination
  end

  def test_filename_conflict_resolution_against_the_real_filesystem
    # A file already on disk with no database row must not be overwritten.
    File.write(download_path('report.pdf'), 'existing')

    download = @coordinator.start_download('https://example.com/report.pdf', download_path('report.pdf'))

    assert_equal download_path('report (1).pdf'), download.destination
  end

  def test_pause_and_resume_flow
    download = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    @coordinator.update_progress(download.id, bytes_received: 500, total_bytes: 1000)

    # User pauses: the transfer stops, the bytes so far are kept.
    paused = @coordinator.pause_download(download.id)

    assert_equal :paused, paused.state
    assert_equal 500, paused.bytes_received
    assert_equal :paused, @repository.find_by_id(download.id).state

    # A paused download still counts as active, and drives the badge.
    assert_includes @coordinator.get_active_downloads.map(&:id), download.id
    assert_equal :paused, @coordinator.badge_state

    # User resumes: a fresh transfer to the same destination, from zero.
    resumed = @coordinator.resume_download(download.id)

    assert_equal :in_progress, resumed.state
    assert_equal 0, resumed.bytes_received
    assert_equal download_path('file.pdf'), resumed.destination
    assert_equal 1, @coordinator.get_all_downloads.length

    # And it can then finish normally.
    @coordinator.update_progress(download.id, bytes_received: 1000, total_bytes: 1000)
    completed = @coordinator.mark_completed(download.id)

    assert_equal :completed, completed.state
    assert_equal :none, @coordinator.badge_state
  end

  def test_retry_flow_reuses_the_failed_record
    download = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    @coordinator.mark_failed(download.id, 'Connection reset')

    retried = @coordinator.resume_download(download.id)

    assert_equal download.id, retried.id
    assert_equal :in_progress, retried.state
    assert_nil retried.error_message
    assert_equal 1, @coordinator.get_all_downloads.length
  end

  def test_old_records_are_discarded_but_recent_ones_are_kept
    old_record = Download.new(
      url: 'https://example.com/ancient.pdf',
      destination: download_path('ancient.pdf'),
      created_at: Time.now - (31 * 24 * 3600)
    )
    @repository.save(old_record)
    recent = @coordinator.start_download('https://example.com/recent.pdf', download_path('recent.pdf'))

    @coordinator.cleanup_old_downloads

    remaining = @coordinator.get_all_downloads
    assert_equal [recent.id], remaining.map(&:id)
  end

  def test_get_active_downloads
    # Create multiple downloads in different states
    pending = @coordinator.start_download('https://example.com/pending.pdf', download_path('pending.pdf'))

    in_progress = @coordinator.start_download('https://example.com/in_progress.pdf', download_path('in_progress.pdf'))
    @coordinator.update_progress(in_progress.id, bytes_received: 500, total_bytes: 1000)

    completed = @coordinator.start_download('https://example.com/completed.pdf', download_path('completed.pdf'))
    @coordinator.update_progress(completed.id, bytes_received: 1000, total_bytes: 1000)
    @coordinator.mark_completed(completed.id)

    failed = @coordinator.start_download('https://example.com/failed.pdf', download_path('failed.pdf'))
    @coordinator.mark_failed(failed.id, 'Error')

    # Get active downloads
    active = @coordinator.get_active_downloads

    assert_equal 2, active.length
    active_ids = active.map(&:id)
    assert_includes active_ids, pending.id
    assert_includes active_ids, in_progress.id
    refute_includes active_ids, completed.id
    refute_includes active_ids, failed.id
  end

  def test_immutability_of_download_objects
    download = @coordinator.start_download('https://example.com/file.pdf', download_path('file.pdf'))
    original_state = download.state

    # Update progress returns new object
    updated = @coordinator.update_progress(download.id, bytes_received: 500, total_bytes: 1000)

    # Original should be unchanged (immutability)
    assert_equal original_state, download.state
    assert_equal :in_progress, updated.state
  end
end
