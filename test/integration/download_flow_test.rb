require 'minitest/autorun'
require 'fileutils'
require 'tempfile'
require_relative '../../lib/domain/download'
require_relative '../../lib/adapters/download_repository'
require_relative '../../lib/managers/download_coordinator'

# Integration test for the download flow without mocks
# Tests: Repository <-> Coordinator <-> Download domain
class DownloadFlowTest < Minitest::Test
  def setup
    @temp_db = Tempfile.new(['downloads', '.db'])
    @temp_db_path = @temp_db.path
    @temp_db.close

    @repository = DownloadRepository.new(db_path: @temp_db_path)
    @coordinator = DownloadCoordinator.new(@repository)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@temp_db_path)
  end

  def test_happy_path_download_start_to_completion
    # 1. Start a download
    url = 'https://example.com/file.pdf'
    destination = '/tmp/test_download.pdf'

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
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
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
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
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
    download1 = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    download2 = @coordinator.start_download('https://example.com/other/file.pdf', '/tmp/file.pdf')

    # Second download should have resolved filename
    assert_equal '/tmp/file.pdf', download1.destination
    assert_equal '/tmp/file (1).pdf', download2.destination
  end

  def test_get_active_downloads
    # Create multiple downloads in different states
    pending = @coordinator.start_download('https://example.com/pending.pdf', '/tmp/pending.pdf')

    in_progress = @coordinator.start_download('https://example.com/in_progress.pdf', '/tmp/in_progress.pdf')
    @coordinator.update_progress(in_progress.id, bytes_received: 500, total_bytes: 1000)

    completed = @coordinator.start_download('https://example.com/completed.pdf', '/tmp/completed.pdf')
    @coordinator.update_progress(completed.id, bytes_received: 1000, total_bytes: 1000)
    @coordinator.mark_completed(completed.id)

    failed = @coordinator.start_download('https://example.com/failed.pdf', '/tmp/failed.pdf')
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
    download = @coordinator.start_download('https://example.com/file.pdf', '/tmp/file.pdf')
    original_state = download.state

    # Update progress returns new object
    updated = @coordinator.update_progress(download.id, bytes_received: 500, total_bytes: 1000)

    # Original should be unchanged (immutability)
    assert_equal original_state, download.state
    assert_equal :in_progress, updated.state
  end
end
