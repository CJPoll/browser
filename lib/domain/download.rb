# Download - Domain object representing a download's state and behavior
#
# This is a pure, immutable domain object with no side effects:
# - No database operations
# - No file system operations
# - No clock reads: every timestamp is supplied by the caller
# - Pure business logic only
# - All state changes return new instances
#
# Responsibilities:
# - Download state management and transitions
# - Filename conflict resolution
# - State validation
# - Progress tracking
#
class Download
  # Valid download states
  STATES = [
    :pending,      # Download created but not started
    :in_progress,  # Download in progress
    :paused,       # Transfer stopped by the user, destination reserved
    :completed,    # Download finished successfully
    :failed,       # Download failed
    :cancelled     # Download cancelled by user
  ].freeze

  # States in which the download still occupies the active list
  ACTIVE_STATES = [:pending, :in_progress, :paused].freeze

  # States that can be cancelled
  CANCELLABLE_STATES = [:pending, :in_progress, :paused].freeze

  # States from which the transfer can be stopped
  PAUSABLE_STATES = [:pending, :in_progress].freeze

  # States from which a fresh transfer can be started to the same destination.
  # Resume (paused) and Retry (failed) are the same transition: WebKit cannot
  # continue a partial download, so both restart it from zero bytes.
  RESUMABLE_STATES = [:paused, :failed].freeze

  attr_reader :id, :url, :destination, :state, :bytes_received, :total_bytes,
              :error_message, :created_at, :started_at, :completed_at

  # Creates a new Download
  #
  # @param url [String] Source URL
  # @param destination [String] Full path where file will be saved
  # @param id [Integer, nil] Database ID (nil for new downloads)
  # @param state [Symbol] Initial state (defaults to :pending)
  # @param bytes_received [Integer] Bytes downloaded so far
  # @param total_bytes [Integer, nil] Total bytes (nil if unknown)
  # @param error_message [String, nil] Error message for failed downloads
  # @param created_at [Time] Creation timestamp, supplied by the caller
  # @param started_at [Time, nil] Download start timestamp
  # @param completed_at [Time, nil] Completion timestamp
  def initialize(
    url:,
    destination:,
    created_at:,
    id: nil,
    state: :pending,
    bytes_received: 0,
    total_bytes: nil,
    error_message: nil,
    started_at: nil,
    completed_at: nil
  )
    raise ArgumentError, "URL is required" if url.nil? || url.to_s.strip.empty?
    raise ArgumentError, "Destination is required" if destination.nil? || destination.to_s.strip.empty?
    raise ArgumentError, "created_at is required" if created_at.nil?
    raise ArgumentError, "Invalid state: #{state}" unless STATES.include?(state)

    @id = id
    @url = url
    @destination = destination
    @state = state
    @bytes_received = bytes_received || 0
    @total_bytes = total_bytes
    @error_message = error_message
    @created_at = created_at
    @started_at = started_at
    @completed_at = completed_at
  end

  # Returns the filename portion of the destination path
  #
  # @return [String] Filename
  def basename
    File.basename(@destination)
  end

  # Alias for compatibility
  alias_method :filename, :basename

  # Alias for destination_path compatibility
  def destination_path
    @destination
  end

  # Alias for downloaded_bytes compatibility
  def downloaded_bytes
    @bytes_received
  end

  # Check if the download can be cancelled
  #
  # @return [Boolean] True if download can be cancelled
  def can_cancel?
    CANCELLABLE_STATES.include?(@state)
  end

  # Check if the transfer can be stopped
  #
  # @return [Boolean] True if download can be paused
  def can_pause?
    PAUSABLE_STATES.include?(@state)
  end

  # Check if a fresh transfer can be started to the same destination
  #
  # @return [Boolean] True if download can be resumed or retried
  def can_resume?
    RESUMABLE_STATES.include?(@state)
  end

  # Check if download is in a terminal state
  #
  # @return [Boolean] True if download is completed, failed, or cancelled
  def terminal_state?
    [:completed, :failed, :cancelled].include?(@state)
  end

  # Check if download is active
  #
  # @return [Boolean] True if download is pending or in_progress
  def active?
    ACTIVE_STATES.include?(@state)
  end

  # Returns a new Download marked as completed
  #
  # @param now [Time] Time at which the download completed
  # @return [Download] New download instance with completed state
  def mark_completed(now:)
    with(state: :completed, completed_at: now)
  end

  # Returns a new Download marked as failed
  #
  # @param message [String] Error message describing the failure
  # @param now [Time] Time at which the download failed
  # @return [Download] New download instance with failed state
  def mark_failed(message, now:)
    with(state: :failed, error_message: message, completed_at: now)
  end

  # Returns a new Download marked as cancelled
  #
  # @param now [Time] Time at which the download was cancelled
  # @return [Download] New download instance with cancelled state
  def mark_cancelled(now:)
    with(state: :cancelled, completed_at: now)
  end

  # Returns a new Download marked as in progress
  #
  # @param now [Time] Time at which the download started
  # @return [Download] New download instance with in_progress state
  def mark_started(now:)
    with(state: :in_progress, started_at: now)
  end

  # Returns a new Download marked as paused
  #
  # The bytes received so far are kept so the UI can report progress, but no
  # timestamp is written: the schema has no paused_at column, and adding one
  # would be a schema change. This transition therefore needs no clock.
  #
  # @return [Download] New download instance with paused state
  def mark_paused
    with(state: :paused)
  end

  # Returns a new Download restarted from the beginning
  #
  # Resume and retry both start a fresh transfer to the same destination, so
  # the byte count restarts at zero and any previous error is cleared.
  #
  # @param now [Time] Time at which the new transfer started
  # @return [Download] New download instance with in_progress state
  def mark_resumed(now:)
    with(
      state: :in_progress,
      started_at: now,
      bytes_received: 0,
      error_message: nil,
      completed_at: nil
    )
  end

  # Calculates progress percentage
  #
  # @return [Float, nil] Percentage (0-100) or nil if total is unknown
  def progress_percentage
    return nil if @total_bytes.nil?
    return 0.0 if @total_bytes == 0
    (@bytes_received.to_f / @total_bytes * 100).round(2)
  end

  # Returns a new Download with updated attributes
  #
  # @param attrs [Hash] Attributes to update
  # @return [Download] New download instance with updated attributes
  def with(**attrs)
    Download.new(
      id: attrs.fetch(:id, @id),
      url: attrs.fetch(:url, @url),
      destination: attrs.fetch(:destination, @destination),
      state: attrs.fetch(:state, @state),
      bytes_received: attrs.fetch(:bytes_received, @bytes_received),
      total_bytes: attrs.fetch(:total_bytes, @total_bytes),
      error_message: attrs.fetch(:error_message, @error_message),
      created_at: attrs.fetch(:created_at, @created_at),
      started_at: attrs.fetch(:started_at, @started_at),
      completed_at: attrs.fetch(:completed_at, @completed_at)
    )
  end

  # Returns a new Download with an assigned ID
  #
  # @param new_id [Integer] The database ID
  # @return [Download] New download instance with ID
  def with_id(new_id)
    with(id: new_id)
  end

  # Equality based on ID
  #
  # @param other [Download] Other download to compare
  # @return [Boolean] True if IDs match
  def ==(other)
    return false unless other.is_a?(Download)
    @id == other.id
  end

  # Names the counter-th alternative to a destination path
  #
  # Counter 0 is the path itself; higher counters insert " (n)" before the
  # extension. This is the naming rule only -- deciding which counter is free
  # requires knowing what already exists, which is the caller's job (see
  # DownloadCoordinator#resolve_destination).
  #
  # @param filepath [String] Full path to file
  # @param counter [Integer] Alternative number, 0 for the original path
  # @return [String] Full path for that alternative
  def self.numbered_destination(filepath, counter)
    return filepath if counter.zero?

    directory = File.dirname(filepath)
    basename = File.basename(filepath, ".*")
    extension = File.extname(filepath)

    File.join(directory, "#{basename} (#{counter})#{extension}")
  end

  # Extracts filename without any extensions
  # Handles compound extensions like .tar.gz
  #
  # @param filename [String] Filename to process
  # @return [String] Filename without any extensions
  def self.filename_without_extension(filename)
    base = File.basename(filename)
    # Find the first dot and take everything before it
    dot_index = base.index('.')
    dot_index ? base[0...dot_index] : base
  end

  # Extracts file extension
  #
  # @param filename [String] Filename to process
  # @return [String] File extension including dot (e.g., ".pdf")
  def self.file_extension(filename)
    File.extname(filename)
  end

  # Converts to hash representation
  #
  # @return [Hash] Download data as hash
  def to_h
    {
      id: @id,
      url: @url,
      destination: @destination,
      state: @state,
      bytes_received: @bytes_received,
      total_bytes: @total_bytes,
      error_message: @error_message,
      created_at: @created_at,
      started_at: @started_at,
      completed_at: @completed_at
    }
  end
end
