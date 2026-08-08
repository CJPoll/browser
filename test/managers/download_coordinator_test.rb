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
    @coordinator = DownloadCoordinator.new(@repository, clock: @clock)
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
