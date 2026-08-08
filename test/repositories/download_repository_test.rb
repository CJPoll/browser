require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/download_repository'
require_relative '../../lib/domain/download'

class DownloadRepositoryTest < Minitest::Test
  def setup
    @test_db_path = '/tmp/test_downloads.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::DownloadRepository.new(db_path: @test_db_path)
    # Download never reads the clock; its callers supply timestamps. These
    # tests stand in for the Manager that normally does so.
    @now = Time.now
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  # Builds a Download with a caller-supplied creation time.
  def build_download(url:, destination:, created_at: @now, **overrides)
    Download.new(
      url: url,
      destination: destination,
      created_at: created_at,
      **overrides
    )
  end

  def test_save_new_download
    download = build_download(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf'
    )

    saved = @repository.save(download)

    refute_nil saved.id
    assert_equal 'https://example.com/file.pdf', saved.url
    assert_equal '/tmp/file.pdf', saved.destination
    assert_equal :pending, saved.state
  end

  def test_save_updates_existing_download
    download = build_download(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf'
    )

    saved = @repository.save(download)
    updated = saved.mark_started(now: @now + 1)
                   .with(bytes_received: 512, total_bytes: 1024)

    result = @repository.save(updated)

    assert_equal saved.id, result.id
    assert_equal :in_progress, result.state
    assert_equal 512, result.bytes_received
    assert_equal 1024, result.total_bytes
  end

  def test_find_by_id_existing
    download = build_download(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf'
    )
    saved = @repository.save(download)

    found = @repository.find_by_id(saved.id)

    refute_nil found
    assert_equal saved.id, found.id
    assert_equal saved.url, found.url
  end

  def test_find_by_id_nonexistent
    found = @repository.find_by_id(999)

    assert_nil found
  end

  def test_find_all_empty
    downloads = @repository.find_all

    assert_empty downloads
  end

  def test_find_all_returns_newest_first
    old = build_download(
      url: 'https://example.com/old.pdf',
      destination: '/tmp/old.pdf',
      created_at: @now - 3600
    )
    new_dl = build_download(
      url: 'https://example.com/new.pdf',
      destination: '/tmp/new.pdf',
      created_at: @now
    )

    @repository.save(old)
    @repository.save(new_dl)

    downloads = @repository.find_all

    assert_equal 2, downloads.length
    assert_equal 'https://example.com/new.pdf', downloads[0].url
    assert_equal 'https://example.com/old.pdf', downloads[1].url
  end

  def test_find_active_only_returns_pending_and_in_progress
    pending = build_download(
      url: 'https://example.com/pending.pdf',
      destination: '/tmp/pending.pdf'
    )
    in_progress = build_download(
      url: 'https://example.com/in_progress.pdf',
      destination: '/tmp/in_progress.pdf'
    ).mark_started(now: @now + 1)

    completed = build_download(
      url: 'https://example.com/completed.pdf',
      destination: '/tmp/completed.pdf'
    ).mark_started(now: @now + 1).mark_completed(now: @now + 2)

    @repository.save(pending)
    @repository.save(in_progress)
    @repository.save(completed)

    active = @repository.find_active

    assert_equal 2, active.length
    urls = active.map(&:url)
    assert_includes urls, 'https://example.com/pending.pdf'
    assert_includes urls, 'https://example.com/in_progress.pdf'
    refute_includes urls, 'https://example.com/completed.pdf'
  end

  def test_find_by_state
    pending = build_download(
      url: 'https://example.com/pending.pdf',
      destination: '/tmp/pending.pdf'
    )
    failed = build_download(
      url: 'https://example.com/failed.pdf',
      destination: '/tmp/failed.pdf'
    ).mark_started(now: @now + 1).mark_failed('Network error', now: @now + 2)

    @repository.save(pending)
    @repository.save(failed)

    failed_downloads = @repository.find_by_state(:failed)

    assert_equal 1, failed_downloads.length
    assert_equal 'https://example.com/failed.pdf', failed_downloads[0].url
    assert_equal 'Network error', failed_downloads[0].error_message
  end

  def test_delete_removes_download
    download = build_download(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf'
    )
    saved = @repository.save(download)

    @repository.delete(saved.id)

    found = @repository.find_by_id(saved.id)
    assert_nil found
  end

  def test_delete_all_removes_everything
    3.times do |i|
      download = build_download(
        url: "https://example.com/file#{i}.pdf",
        destination: "/tmp/file#{i}.pdf"
      )
      @repository.save(download)
    end

    @repository.delete_all

    downloads = @repository.find_all
    assert_empty downloads
  end

  def test_delete_by_state
    completed = build_download(
      url: 'https://example.com/completed.pdf',
      destination: '/tmp/completed.pdf'
    ).mark_started(now: @now + 1).mark_completed(now: @now + 2)

    failed = build_download(
      url: 'https://example.com/failed.pdf',
      destination: '/tmp/failed.pdf'
    ).mark_started(now: @now + 1).mark_failed('Error', now: @now + 2)

    pending = build_download(
      url: 'https://example.com/pending.pdf',
      destination: '/tmp/pending.pdf'
    )

    @repository.save(completed)
    @repository.save(failed)
    @repository.save(pending)

    @repository.delete_by_state(:completed)

    downloads = @repository.find_all
    assert_equal 2, downloads.length
    urls = downloads.map(&:url)
    refute_includes urls, 'https://example.com/completed.pdf'
  end

  def test_delete_older_than
    # delete_older_than compares against the real clock, so these ages are
    # anchored to Time.now rather than a fixed instant.
    old = build_download(
      url: 'https://example.com/old.pdf',
      destination: '/tmp/old.pdf',
      created_at: Time.now - (31 * 24 * 3600) # 31 days ago
    )
    recent = build_download(
      url: 'https://example.com/recent.pdf',
      destination: '/tmp/recent.pdf',
      created_at: Time.now - (15 * 24 * 3600) # 15 days ago
    )

    @repository.save(old)
    @repository.save(recent)

    @repository.delete_older_than(30) # Delete > 30 days

    downloads = @repository.find_all
    assert_equal 1, downloads.length
    assert_equal 'https://example.com/recent.pdf', downloads[0].url
  end

  def test_find_existing_paths_empty
    paths = @repository.find_existing_paths(['/tmp/file.pdf'])

    assert_empty paths
  end

  def test_find_existing_paths_finds_matches
    download1 = build_download(
      url: 'https://example.com/file1.pdf',
      destination: '/tmp/file1.pdf'
    )
    download2 = build_download(
      url: 'https://example.com/file2.pdf',
      destination: '/tmp/file2.pdf'
    )

    @repository.save(download1)
    @repository.save(download2)

    paths = @repository.find_existing_paths([
      '/tmp/file1.pdf',
      '/tmp/file3.pdf',
      '/tmp/file2.pdf'
    ])

    assert_equal 2, paths.length
    assert_includes paths, '/tmp/file1.pdf'
    assert_includes paths, '/tmp/file2.pdf'
    refute_includes paths, '/tmp/file3.pdf'
  end

  def test_preserves_timestamps
    download = build_download(
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf'
    ).mark_started(now: @now + 1).mark_completed(now: @now + 2)

    saved = @repository.save(download)
    found = @repository.find_by_id(saved.id)

    # Timestamps round-trip through integer Unix seconds.
    assert_equal @now.to_i, found.created_at.to_i
    assert_equal (@now + 1).to_i, found.started_at.to_i
    assert_equal (@now + 2).to_i, found.completed_at.to_i
  end

  def test_thread_safety
    threads = 10.times.map do |i|
      Thread.new do
        download = build_download(
          url: "https://example.com/file#{i}.pdf",
          destination: "/tmp/file#{i}.pdf"
        )
        @repository.save(download)
      end
    end

    threads.each(&:join)

    downloads = @repository.find_all
    assert_equal 10, downloads.length
  end
end
