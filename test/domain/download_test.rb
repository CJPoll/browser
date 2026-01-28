require 'minitest/autorun'
require_relative '../../lib/domain/download'

class DownloadTest < Minitest::Test
  def test_new_download_creation
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    assert_equal 1, download.id
    assert_equal 'https://example.com/file.pdf', download.url
    assert_equal '/tmp/file.pdf', download.destination
    assert_equal :in_progress, download.state
  end

  def test_state_validation
    valid_states = [:pending, :in_progress, :completed, :failed, :cancelled]
    
    valid_states.each do |state|
      download = Download.new(
        id: 1,
        url: 'https://example.com/file.pdf',
        destination: '/tmp/file.pdf',
        state: state
      )
      assert_equal state, download.state
    end
  end

  def test_invalid_state_raises_error
    error = assert_raises(ArgumentError) do
      Download.new(
        id: 1,
        url: 'https://example.com/file.pdf',
        destination: '/tmp/file.pdf',
        state: :invalid_state
      )
    end

    assert_match(/invalid state/i, error.message)
  end

  def test_can_cancel_when_in_progress
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    assert download.can_cancel?
  end

  def test_can_cancel_when_pending
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :pending
    )

    assert download.can_cancel?
  end

  def test_cannot_cancel_when_completed
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :completed
    )

    refute download.can_cancel?
  end

  def test_cannot_cancel_when_failed
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :failed
    )

    refute download.can_cancel?
  end

  def test_cannot_cancel_when_already_cancelled
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :cancelled
    )

    refute download.can_cancel?
  end

  def test_state_transition_to_completed
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    updated = download.mark_completed

    assert_equal :completed, updated.state
    assert_equal :in_progress, download.state # Original unchanged (immutable)
  end

  def test_state_transition_to_failed
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress,
      error_message: nil
    )

    updated = download.mark_failed('Network error')

    assert_equal :failed, updated.state
    assert_equal 'Network error', updated.error_message
    assert_equal :in_progress, download.state # Original unchanged
  end

  def test_state_transition_to_cancelled
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    updated = download.mark_cancelled

    assert_equal :cancelled, updated.state
    assert_equal :in_progress, download.state # Original unchanged
  end

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

  def test_equality_based_on_id
    download1 = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    download2 = Download.new(
      id: 1,
      url: 'https://example.com/other.pdf',
      destination: '/tmp/other.pdf',
      state: :completed
    )

    assert_equal download1, download2
  end

  def test_inequality_different_ids
    download1 = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    download2 = Download.new(
      id: 2,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress
    )

    refute_equal download1, download2
  end

  def test_with_updated_attributes
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
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
    assert_equal 1024, download.bytes_received # Original unchanged
  end

  def test_progress_percentage
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress,
      bytes_received: 512,
      total_bytes: 1024
    )

    assert_equal 50.0, download.progress_percentage
  end

  def test_progress_percentage_when_total_unknown
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress,
      bytes_received: 512,
      total_bytes: nil
    )

    assert_nil download.progress_percentage
  end

  def test_progress_percentage_when_total_zero
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      state: :in_progress,
      bytes_received: 0,
      total_bytes: 0
    )

    assert_equal 0.0, download.progress_percentage
  end

  def test_basename
    download = Download.new(
      id: 1,
      url: 'https://example.com/file.pdf',
      destination: '/home/user/Downloads/file.pdf',
      state: :in_progress
    )

    assert_equal 'file.pdf', download.basename
  end
end
