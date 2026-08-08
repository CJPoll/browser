# frozen_string_literal: true

require_relative '../domain/download'

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
  # Creates a new DownloadCoordinator
  #
  # Owns the clock on behalf of the Download domain object, which never reads
  # it. Tests inject a controllable clock to make timestamps deterministic.
  #
  # @param repository [Repositories::DownloadRepository] Repository for persisting downloads
  # @param clock [#call] Returns the current Time
  def initialize(repository, clock: -> { Time.now })
    @repository = repository
    @clock = clock
  end

  # Starts a new download
  #
  # @param url [String] Source URL
  # @param destination [String] Intended destination path
  # @return [Download] The created download with resolved destination path
  def start_download(url, destination)
    # Resolve filename conflicts
    existing_paths = @repository.find_existing_paths([destination])
    resolved_destination = Download.resolve_filename_conflict(destination, existing_paths)

    # Create and persist download
    download = Download.new(
      url: url,
      destination: resolved_destination,
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
end
