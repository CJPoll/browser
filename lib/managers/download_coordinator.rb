# frozen_string_literal: true

require_relative '../adapters/file_system'
require_relative '../domain/download'
require_relative '../domain/download_badge'
require_relative '../repositories/download_repository'

# DownloadCoordinator orchestrates download operations between the UI layer
# and Repositories::DownloadRepository.
#
# This is a Manager layer component that:
# - Coordinates between the repository and domain (Download)
# - Contains no business logic (delegates to Download domain object)
# - Contains no persistence logic (delegates to the repository)
# - Returns Download domain objects to UI
#
# Thread Safety: All operations are synchronous. Caller is responsible
# for thread safety when using from multiple threads.
class DownloadCoordinator
  # How long finished download records are kept before cleanup_old_downloads
  # discards them.
  RETENTION_DAYS = 30

  # How often the Framework should call cleanup_old_downloads.
  CLEANUP_INTERVAL_SECONDS = 300

  # Creates a new DownloadCoordinator
  #
  # Owns the clock on behalf of the Download domain object, which never reads
  # it. Tests inject a controllable clock to make timestamps deterministic.
  #
  # @param repository [Repositories::DownloadRepository] Repository for persisting downloads
  # @param clock [#call] Returns the current Time
  # @param file_system [Adapters::FileSystem] Answers what already exists on disk
  def initialize(repository = Repositories::DownloadRepository.new,
                 clock: -> { Time.now },
                 file_system: Adapters::FileSystem.new)
    @repository = repository
    @clock = clock
    @file_system = file_system
  end

  # Starts a new download
  #
  # @param url [String] Source URL
  # @param destination [String] Intended destination path
  # @return [Download] The created download with resolved destination path
  def start_download(url, destination)
    download = Download.new(
      url: url,
      destination: resolve_destination(destination),
      created_at: @clock.call
    )
    @repository.save(download)
  end

  # Updates download progress
  #
  # @param download_id [Integer] Download ID
  # @param bytes_received [Integer] Bytes downloaded so far
  # @param total_bytes [Integer, nil] Total bytes (nil if unknown)
  # @return [Download, nil] Updated download or nil if not found
  def update_progress(download_id, bytes_received:, total_bytes: nil)
    download = @repository.find_by_id(download_id)
    return nil unless download

    # Transition to in_progress if still pending
    updated = if download.state == :pending
                download.mark_started(now: @clock.call)
                        .with(bytes_received: bytes_received, total_bytes: total_bytes)
              else
                download.with(bytes_received: bytes_received, total_bytes: total_bytes)
              end

    @repository.save(updated)
  end

  # Marks a download as completed
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Updated download or nil if not found
  def mark_completed(download_id)
    download = @repository.find_by_id(download_id)
    return nil unless download

    updated = download.mark_completed(now: @clock.call)
    @repository.save(updated)
  end

  # Marks a download as failed
  #
  # @param download_id [Integer] Download ID
  # @param error_message [String] Error description
  # @return [Download, nil] Updated download or nil if not found
  def mark_failed(download_id, error_message)
    download = @repository.find_by_id(download_id)
    return nil unless download

    updated = download.mark_failed(error_message, now: @clock.call)
    @repository.save(updated)
  end

  # Cancels a download
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Updated download, or nil if not found or cannot cancel
  def cancel_download(download_id)
    download = @repository.find_by_id(download_id)
    return nil unless download
    return nil unless download.can_cancel?

    updated = download.mark_cancelled(now: @clock.call)
    @repository.save(updated)
  end

  # Pauses a download
  #
  # WebKit cannot suspend a transfer, so the caller cancels the underlying
  # WebKit download; this records the intent and keeps the bytes received so
  # far. The destination stays reserved for the eventual resume.
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Updated download, or nil if not found or not running
  def pause_download(download_id)
    download = @repository.find_by_id(download_id)
    return nil unless download
    return nil unless download.can_pause?

    @repository.save(download.mark_paused)
  end

  # Resumes (or retries) a download
  #
  # The transfer restarts from zero against the same destination -- the caller
  # is expected to kick off a fresh WebKit download for the returned record.
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Updated download, or nil if not found or not resumable
  def resume_download(download_id)
    download = @repository.find_by_id(download_id)
    return nil unless download
    return nil unless download.can_resume?

    @repository.save(download.mark_resumed(now: @clock.call))
  end

  # Gets a download by ID
  #
  # @param download_id [Integer] Download ID
  # @return [Download, nil] Download or nil if not found
  def get_download(download_id)
    @repository.find_by_id(download_id)
  end

  # Gets all downloads
  #
  # @return [Array<Download>] All downloads, newest first
  def get_all_downloads
    @repository.find_all
  end

  # Gets active downloads (pending or in_progress)
  #
  # @return [Array<Download>] Active downloads
  def get_active_downloads
    @repository.find_active
  end

  # Deletes a download record
  #
  # @param download_id [Integer] Download ID
  # @return [Boolean] True if deleted, false if not found
  def delete_download(download_id)
    @repository.delete(download_id)
  end

  # Number of downloads on record, in any state
  #
  # @return [Integer] Total downloads
  def download_count
    @repository.find_all.length
  end

  # Number of downloads still in flight
  #
  # @return [Integer] Active downloads
  def active_download_count
    @repository.find_active.length
  end

  # Toolbar badge state for the current downloads
  #
  # @return [Symbol] :none, :paused, or :active
  def badge_state
    Domain::DownloadBadge.state(@repository.find_active)
  end

  # Discards download records older than the retention period
  #
  # Records only -- the downloaded files themselves are never touched. The
  # Framework schedules this every CLEANUP_INTERVAL_SECONDS.
  #
  # @param retention_days [Integer] Age beyond which records are discarded
  # @return [void]
  def cleanup_old_downloads(retention_days: RETENTION_DAYS)
    @repository.delete_older_than(retention_days)
  end

  private

  # Finds the first destination path not already claimed by a download record
  # or by a file on disk.
  #
  # @param destination [String] Intended destination path
  # @return [String] A free destination path
  def resolve_destination(destination)
    counter = 0

    loop do
      candidate = Download.numbered_destination(destination, counter)
      return candidate unless destination_taken?(candidate)

      counter += 1
    end
  end

  def destination_taken?(path)
    !@repository.find_existing_paths([path]).empty? || @file_system.exist?(path)
  end
end
