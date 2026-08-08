require 'minitest/autorun'
require_relative '../../lib/domain/download'

class DownloadTest < Minitest::Test
  # Fixed timestamps so every assertion about time is deterministic.
  CREATED_AT = Time.at(1_700_000_000).freeze
  NOW = Time.at(1_700_003_600).freeze

  # Builds a Download with sensible defaults, overridable per test.
  def build_download(**overrides)
    Download.new(**{
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      created_at: CREATED_AT
    }.merge(overrides))
  end

  # ========================================
  # Construction and Validation
  # ========================================

  def test_new_download_creation
    download = build_download(state: :in_progress)

    assert_equal 1, download.id
    assert_equal 'https://example.com/file.pdf', download.url
    assert_equal '/tmp/file.pdf', download.destination
    assert_equal :in_progress, download.state
    assert_equal CREATED_AT, download.created_at
  end

  def test_state_validation
    valid_states = [:pending, :in_progress, :completed, :failed, :cancelled]

    valid_states.each do |state|
      download = build_download(state: state)
      assert_equal state, download.state
    end
  end

  def test_invalid_state_raises_error
    error = assert_raises(ArgumentError) do
      build_download(state: :invalid_state)
    end

    assert_match(/invalid state/i, error.message)
  end

  def test_missing_url_raises_error
    error = assert_raises(ArgumentError) do
      build_download(url: '  ')
    end

    assert_match(/url is required/i, error.message)
  end

  def test_missing_destination_raises_error
    error = assert_raises(ArgumentError) do
      build_download(destination: nil)
    end

    assert_match(/destination is required/i, error.message)
  end

  def test_created_at_must_be_supplied
    # The domain never reads the clock: creation time is injected by the caller.
    assert_raises(ArgumentError) do
      Download.new(
        url: 'https://example.com/file.pdf',
        destination: '/tmp/file.pdf'
      )
    end
  end

  def test_nil_created_at_raises_error
    error = assert_raises(ArgumentError) do
      build_download(created_at: nil)
    end

    assert_match(/created_at is required/i, error.message)
  end

  # ========================================
  # Cancellability
  # ========================================

  def test_can_cancel_when_in_progress
    assert build_download(state: :in_progress).can_cancel?
  end

  def test_can_cancel_when_pending
    assert build_download(state: :pending).can_cancel?
  end

  def test_cannot_cancel_when_completed
    refute build_download(state: :completed).can_cancel?
  end

  def test_cannot_cancel_when_failed
    refute build_download(state: :failed).can_cancel?
  end

  def test_cannot_cancel_when_already_cancelled
    refute build_download(state: :cancelled).can_cancel?
  end

  # ========================================
  # State Predicates
  # ========================================

  def test_active_states
    assert build_download(state: :pending).active?
    assert build_download(state: :in_progress).active?
    refute build_download(state: :completed).active?
    refute build_download(state: :failed).active?
    refute build_download(state: :cancelled).active?
  end

  def test_terminal_states
    refute build_download(state: :pending).terminal_state?
    refute build_download(state: :in_progress).terminal_state?
    assert build_download(state: :completed).terminal_state?
    assert build_download(state: :failed).terminal_state?
    assert build_download(state: :cancelled).terminal_state?
  end

  # ========================================
  # State Transitions
  # ========================================

  def test_state_transition_to_started
    download = build_download(state: :pending)

    updated = download.mark_started(now: NOW)

    assert_equal :in_progress, updated.state
    assert_equal NOW, updated.started_at
    assert_equal :pending, download.state # Original unchanged (immutable)
    assert_nil download.started_at
  end

  def test_state_transition_to_completed
    download = build_download(state: :in_progress)

    updated = download.mark_completed(now: NOW)

    assert_equal :completed, updated.state
    assert_equal NOW, updated.completed_at
    assert_equal :in_progress, download.state # Original unchanged (immutable)
    assert_nil download.completed_at
  end

  def test_state_transition_to_failed
    download = build_download(state: :in_progress, error_message: nil)

    updated = download.mark_failed('Network error', now: NOW)

    assert_equal :failed, updated.state
    assert_equal 'Network error', updated.error_message
    assert_equal NOW, updated.completed_at
    assert_equal :in_progress, download.state # Original unchanged
  end

  def test_state_transition_to_cancelled
    download = build_download(state: :in_progress)

    updated = download.mark_cancelled(now: NOW)

    assert_equal :cancelled, updated.state
    assert_equal NOW, updated.completed_at
    assert_equal :in_progress, download.state # Original unchanged
  end

  def test_transitions_require_an_injected_time
    download = build_download(state: :in_progress)

    assert_raises(ArgumentError) { download.mark_started }
    assert_raises(ArgumentError) { download.mark_completed }
    assert_raises(ArgumentError) { download.mark_failed('boom') }
    assert_raises(ArgumentError) { download.mark_cancelled }
  end

  def test_transitions_preserve_created_at
    download = build_download(state: :pending)

    assert_equal CREATED_AT, download.mark_started(now: NOW).created_at
    assert_equal CREATED_AT, download.mark_completed(now: NOW).created_at
    assert_equal CREATED_AT, download.mark_failed('boom', now: NOW).created_at
    assert_equal CREATED_AT, download.mark_cancelled(now: NOW).created_at
  end

  def test_completion_preserves_started_at
    started = build_download(state: :pending).mark_started(now: NOW)

    completed = started.mark_completed(now: NOW + 60)

    assert_equal NOW, completed.started_at
    assert_equal NOW + 60, completed.completed_at
  end

  # ========================================
  # Filename Helpers
  # ========================================

  def test_filename_without_extension
    assert_equal 'file', Download.filename_without_extension('file.pdf')
    assert_equal 'document', Download.filename_without_extension('document.tar.gz')
    assert_equal 'noext', Download.filename_without_extension('noext')
  end

  def test_file_extension
    assert_equal '.pdf', Download.file_extension('file.pdf')
    assert_equal '.gz', Download.file_extension('document.tar.gz')
    assert_equal '', Download.file_extension('noext')
  end

  def test_resolve_filename_conflict_no_conflict
    existing = []

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file.pdf', result
  end

  def test_resolve_filename_conflict_one_conflict
    existing = ['/downloads/file.pdf']

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file (1).pdf', result
  end

  def test_resolve_filename_conflict_multiple_conflicts
    existing = [
      '/downloads/file.pdf',
      '/downloads/file (1).pdf',
      '/downloads/file (2).pdf'
    ]

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file (3).pdf', result
  end

  def test_resolve_filename_conflict_gaps_in_numbering
    # If user deleted file (2), we should use (2), not (4)
    existing = [
      '/downloads/file.pdf',
      '/downloads/file (1).pdf',
      '/downloads/file (3).pdf'
    ]

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file (2).pdf', result
  end

  def test_resolve_filename_conflict_no_extension
    existing = [
      '/downloads/README',
      '/downloads/README (1)'
    ]

    result = Download.resolve_filename_conflict(
      '/downloads/README',
      existing
    )

    assert_equal '/downloads/README (2)', result
  end

  def test_resolve_filename_conflict_preserves_directory
    existing = [
      '/home/user/Downloads/file.pdf',
      '/home/user/Downloads/file (1).pdf'
    ]

    result = Download.resolve_filename_conflict(
      '/home/user/Downloads/file.pdf',
      existing
    )

    assert_equal '/home/user/Downloads/file (2).pdf', result
  end

  def test_resolve_filename_conflict_different_extension_not_conflict
    # file.pdf and file.txt are different files, no conflict
    existing = ['/downloads/file.txt']

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file.pdf', result
  end

  def test_resolve_filename_conflict_case_sensitive
    # On case-sensitive filesystems, File.pdf != file.pdf
    existing = ['/downloads/File.pdf']

    result = Download.resolve_filename_conflict(
      '/downloads/file.pdf',
      existing
    )

    assert_equal '/downloads/file.pdf', result
  end

  def test_resolve_filename_conflict_numbered_base_name
    # If the base filename already has (1) in it, don't get confused
    existing = [
      '/downloads/file (1).pdf',
      '/downloads/file (1) (1).pdf'
    ]

    result = Download.resolve_filename_conflict(
      '/downloads/file (1).pdf',
      existing
    )

    assert_equal '/downloads/file (1) (2).pdf', result
  end

  # ========================================
  # Equality and Copying
  # ========================================

  def test_equality_based_on_id
    download1 = build_download(id: 1, state: :in_progress)
    download2 = build_download(
      id: 1,
      url: 'https://example.com/other.pdf',
      destination: '/tmp/other.pdf',
      state: :completed
    )

    assert_equal download1, download2
  end

  def test_inequality_different_ids
    download1 = build_download(id: 1, state: :in_progress)
    download2 = build_download(id: 2, state: :in_progress)

    refute_equal download1, download2
  end

  def test_with_updated_attributes
    download = build_download(
      state: :in_progress,
      bytes_received: 1024,
      total_bytes: 2048
    )

    updated = download.with(
      bytes_received: 2048,
      state: :completed
    )

    assert_equal 2048, updated.bytes_received
    assert_equal :completed, updated.state
    assert_equal 2048, updated.total_bytes # Unchanged attributes preserved
    assert_equal CREATED_AT, updated.created_at
    assert_equal 1024, download.bytes_received # Original unchanged
  end

  def test_with_id
    download = build_download(id: nil)

    assert_equal 7, download.with_id(7).id
    assert_nil download.id # Original unchanged
  end

  # ========================================
  # Progress
  # ========================================

  def test_progress_percentage
    download = build_download(
      state: :in_progress,
      bytes_received: 512,
      total_bytes: 1024
    )

    assert_equal 50.0, download.progress_percentage
  end

  def test_progress_percentage_when_total_unknown
    download = build_download(
      state: :in_progress,
      bytes_received: 512,
      total_bytes: nil
    )

    assert_nil download.progress_percentage
  end

  def test_progress_percentage_when_total_zero
    download = build_download(
      state: :in_progress,
      bytes_received: 0,
      total_bytes: 0
    )

    assert_equal 0.0, download.progress_percentage
  end

  def test_basename
    download = build_download(
      state: :in_progress,
      destination: '/home/user/Downloads/file.pdf'
    )

    assert_equal 'file.pdf', download.basename
  end

  def test_to_h_includes_injected_timestamps
    download = build_download(state: :pending).mark_started(now: NOW)

    hash = download.to_h

    assert_equal CREATED_AT, hash[:created_at]
    assert_equal NOW, hash[:started_at]
    assert_nil hash[:completed_at]
  end
end
