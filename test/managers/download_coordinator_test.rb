require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/domain/download'

# Mock repository for testing
class MockDownloadRepository
  def initialize
    @downloads = {}
    @next_id = 1
  end

  def save(download)
    if download.id
      @downloads[download.id] = download
      download
    else
      new_download = download.with_id(@next_id)
      @downloads[@next_id] = new_download
      @next_id += 1
      new_download
    end
  end

  def find_by_id(id)
    @downloads[id]
  end

  def find_all
    @downloads.values.sort_by { |d| -d.created_at.to_i }
  end

  def find_active
    @downloads.values.select(&:active?).sort_by { |d| -d.created_at.to_i }
  end

  def find_existing_paths(paths)
    existing = @downloads.values.map(&:destination)
    paths & existing
  end

  def delete(id)
    !!@downloads.delete(id)
  end

  def delete_older_than(days)
    @deleted_older_than = days
  end

  attr_reader :deleted_older_than
end

# Stands in for the filesystem so tests never depend on what is really on disk.
class MockFileSystem
  def initialize(existing = [])
    @existing = existing
  end

  def exist?(path)
    @existing.include?(path)
  end
end

# Controllable clock so timestamps written by the coordinator are assertable.
class TestClock
  def initialize(start)
    @time = start
  end

  def call
    @time
  end

  def advance(seconds)
    @time += seconds
    self
  end
end

# Load the coordinator after defining mock
require_relative '../../lib/managers/download_coordinator'

class DownloadCoordinatorTest < Minitest::Test
  START_TIME = Time.at(1_700_000_000).freeze

  def setup
    @repository = MockDownloadRepository.new
    @clock = TestClock.new(START_TIME)
    @file_system = MockFileSystem.new
    @coordinator = DownloadCoordinator.new(
      @repository,
      clock: @clock,
      file_system: @file_system
    )
  end

  # Builds a coordinator whose filesystem already holds the given paths.
  def coordinator_with_files_on_disk(*paths)
    DownloadCoordinator.new(
      @repository,
      clock: @clock,
      file_system: MockFileSystem.new(paths)
    )
  end

  def test_start_download_creates_download_record
    url = 'https://example.com/file.pdf'
    destination = '/tmp/file.pdf'

    download = @coordinator.start_download(url, destination)

    refute_nil download.id, "Download should have an ID"
    assert_equal url, download.url
    assert_equal destination, download.destination
    assert_equal :pending, download.state
  end

  def test_start_download_stamps_created_at_from_the_clock
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    assert_equal START_TIME, download.created_at
  end

  def test_start_download_resolves_filename_conflicts
    url1 = 'https://example.com/file.pdf'
    url2 = 'https://example.com/other/file.pdf'
    destination = '/tmp/file.pdf'

    download1 = @coordinator.start_download(url1, destination)
    download2 = @coordinator.start_download(url2, destination)

    assert_equal '/tmp/file.pdf', download1.destination
    assert_equal '/tmp/file (1).pdf', download2.destination
  end

  def test_start_download_keeps_counting_past_the_first_conflict
    3.times { @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf') }

    fourth = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    assert_equal '/tmp/file (3).pdf', fourth.destination
  end

  def test_start_download_fills_gaps_in_the_numbering
    first = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    second = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.delete_download(second.id)

    replacement = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    assert_equal '/tmp/file.pdf', first.destination
    assert_equal '/tmp/file (1).pdf', replacement.destination
  end

  def test_start_download_avoids_files_already_on_disk
    # A file can exist on disk without a database row -- put there by another
    # program, or left behind after the history was cleared. Never clobber it.
    coordinator = coordinator_with_files_on_disk('/tmp/file.pdf', '/tmp/file (1).pdf')

    download = coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    assert_equal '/tmp/file (2).pdf', download.destination
  end

  def test_start_download_leaves_an_unused_destination_alone
    coordinator = coordinator_with_files_on_disk('/tmp/other.pdf')

    download = coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    assert_equal '/tmp/file.pdf', download.destination
  end

  def test_update_progress
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    updated = @coordinator.update_progress(download.id, bytes_received: 512, total_bytes: 1024)

    assert_equal :in_progress, updated.state
    assert_equal 512, updated.bytes_received
    assert_equal 1024, updated.total_bytes
    assert_equal 50.0, updated.progress_percentage
  end

  def test_update_progress_stamps_started_at_from_the_clock
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @clock.advance(30)

    updated = @coordinator.update_progress(download.id, bytes_received: 512, total_bytes: 1024)

    assert_equal START_TIME + 30, updated.started_at
  end

  def test_update_progress_leaves_started_at_alone_once_in_progress
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @clock.advance(30)
    @coordinator.update_progress(download.id, bytes_received: 100, total_bytes: 1024)
    @clock.advance(30)

    updated = @coordinator.update_progress(download.id, bytes_received: 512, total_bytes: 1024)

    assert_equal START_TIME + 30, updated.started_at
  end

  def test_mark_completed
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 100, total_bytes: 100)
    @clock.advance(90)

    completed = @coordinator.mark_completed(download.id)

    assert_equal :completed, completed.state
    assert_equal START_TIME + 90, completed.completed_at
  end

  def test_mark_failed
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @clock.advance(5)

    failed = @coordinator.mark_failed(download.id, 'Network error')

    assert_equal :failed, failed.state
    assert_equal 'Network error', failed.error_message
    assert_equal START_TIME + 5, failed.completed_at
  end

  def test_cancel_download
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 50, total_bytes: 100)
    @clock.advance(15)

    cancelled = @coordinator.cancel_download(download.id)

    assert_equal :cancelled, cancelled.state
    assert_equal START_TIME + 15, cancelled.completed_at
  end

  def test_cancel_returns_nil_for_nonexistent_download
    result = @coordinator.cancel_download(999)

    assert_nil result
  end

  def test_cancel_returns_nil_for_already_completed
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 100, total_bytes: 100)
    @coordinator.mark_completed(download.id)

    result = @coordinator.cancel_download(download.id)

    assert_nil result, "Cannot cancel a completed download"
  end

  # ========================================
  # Pause and Resume
  # ========================================

  def test_pause_download_keeps_the_bytes_received
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 512, total_bytes: 1024)

    paused = @coordinator.pause_download(download.id)

    assert_equal :paused, paused.state
    assert_equal 512, paused.bytes_received
    assert_equal :paused, @coordinator.get_download(download.id).state
  end

  def test_pause_returns_nil_for_a_download_that_is_not_running
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.mark_completed(download.id)

    assert_nil @coordinator.pause_download(download.id)
  end

  def test_pause_returns_nil_for_nonexistent_download
    assert_nil @coordinator.pause_download(999)
  end

  def test_resume_restarts_the_transfer_to_the_same_destination
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 512, total_bytes: 1024)
    @coordinator.pause_download(download.id)
    @clock.advance(60)

    resumed = @coordinator.resume_download(download.id)

    assert_equal :in_progress, resumed.state
    assert_equal 0, resumed.bytes_received, "A resumed download starts over"
    assert_equal '/tmp/file.pdf', resumed.destination
    assert_equal START_TIME + 60, resumed.started_at
  end

  def test_resume_reuses_the_record_rather_than_creating_a_second_one
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.pause_download(download.id)

    resumed = @coordinator.resume_download(download.id)

    assert_equal download.id, resumed.id
    assert_equal 1, @coordinator.get_all_downloads.length
  end

  def test_resume_retries_a_failed_download
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.mark_failed(download.id, 'Connection reset')
    @clock.advance(10)

    resumed = @coordinator.resume_download(download.id)

    assert_equal :in_progress, resumed.state
    assert_nil resumed.error_message
  end

  def test_resume_returns_nil_for_a_running_download
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.update_progress(download.id, bytes_received: 10, total_bytes: 1024)

    assert_nil @coordinator.resume_download(download.id)
  end

  def test_resume_returns_nil_for_nonexistent_download
    assert_nil @coordinator.resume_download(999)
  end

  def test_a_paused_download_can_still_be_cancelled
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    @coordinator.pause_download(download.id)
    @clock.advance(5)

    cancelled = @coordinator.cancel_download(download.id)

    assert_equal :cancelled, cancelled.state
    assert_equal START_TIME + 5, cancelled.completed_at
  end

  # ========================================
  # Badge State and Counts
  # ========================================

  def test_badge_state_reports_no_downloads
    assert_equal :none, @coordinator.badge_state
    assert_equal 0, @coordinator.active_download_count
  end

  def test_badge_state_reports_running_downloads
    @coordinator.start_download('https://example.com/a.pdf', '/tmp/a.pdf')
    @coordinator.start_download('https://example.com/b.pdf', '/tmp/b.pdf')

    assert_equal :active, @coordinator.badge_state
    assert_equal 2, @coordinator.active_download_count
  end

  def test_badge_state_reports_paused_downloads
    running = @coordinator.start_download('https://example.com/a.pdf', '/tmp/a.pdf')
    @coordinator.start_download('https://example.com/b.pdf', '/tmp/b.pdf')
    @coordinator.pause_download(running.id)

    assert_equal :paused, @coordinator.badge_state
  end

  def test_download_count_includes_finished_downloads
    completed = @coordinator.start_download('https://example.com/a.pdf', '/tmp/a.pdf')
    @coordinator.mark_completed(completed.id)
    @coordinator.start_download('https://example.com/b.pdf', '/tmp/b.pdf')

    assert_equal 2, @coordinator.download_count
    assert_equal 1, @coordinator.active_download_count
  end

  # ========================================
  # Retention
  # ========================================

  def test_cleanup_old_downloads_uses_the_default_retention
    @coordinator.cleanup_old_downloads

    assert_equal DownloadCoordinator::RETENTION_DAYS, @repository.deleted_older_than
  end

  def test_cleanup_old_downloads_accepts_an_explicit_retention
    @coordinator.cleanup_old_downloads(retention_days: 7)

    assert_equal 7, @repository.deleted_older_than
  end

  def test_get_download
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    found = @coordinator.get_download(download.id)

    assert_equal download.id, found.id
    assert_equal download.url, found.url
  end

  def test_get_all_downloads
    @coordinator.start_download('https://example.com/file1.pdf', '/tmp/file1.pdf')
    @coordinator.start_download('https://example.com/file2.pdf', '/tmp/file2.pdf')

    downloads = @coordinator.get_all_downloads

    assert_equal 2, downloads.length
  end

  def test_get_active_downloads
    active = @coordinator.start_download('https://example.com/active.pdf', '/tmp/active.pdf')
    @coordinator.update_progress(active.id, bytes_received: 50, total_bytes: 100)

    completed = @coordinator.start_download('https://example.com/completed.pdf', '/tmp/completed.pdf')
    @coordinator.update_progress(completed.id, bytes_received: 100, total_bytes: 100)
    @coordinator.mark_completed(completed.id)

    active_downloads = @coordinator.get_active_downloads

    assert_equal 1, active_downloads.length
    assert_equal active.id, active_downloads.first.id
  end

  def test_delete_download
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')

    result = @coordinator.delete_download(download.id)

    assert result, "Delete should return true"
    assert_nil @coordinator.get_download(download.id)
  end
end
