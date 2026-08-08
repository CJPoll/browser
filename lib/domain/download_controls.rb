# frozen_string_literal: true

module Domain
  # DownloadControls says which actions a download offers in its current
  # state.
  #
  # Pure: it returns descriptors, not widgets. The UI Component renders them
  # and reports the chosen intent back to the Framework, which is what turns
  # an intent into a DownloadCoordinator call.
  module DownloadControls
    PAUSE = { intent: :pause, label: '⏸', tooltip: 'Pause' }.freeze
    RESUME = { intent: :resume, label: '▶', tooltip: 'Resume (re-downloads)' }.freeze
    RETRY = { intent: :resume, label: '↻', tooltip: 'Retry' }.freeze
    CANCEL = { intent: :cancel, label: '✕', tooltip: 'Cancel' }.freeze
    REMOVE = { intent: :remove, label: '✕', tooltip: 'Remove' }.freeze
    OPEN_LOCATION = { intent: :open_location, label: '📁', tooltip: 'Open File Location' }.freeze

    # Controls offered for a download, in display order
    #
    # @param download [Download] Download domain object
    # @return [Array<Hash>] Frozen control descriptors
    def self.for(download)
      case download.state
      when :pending, :in_progress then [PAUSE, CANCEL]
      when :paused then [RESUME, CANCEL]
      when :failed then [RETRY, REMOVE]
      when :completed then [OPEN_LOCATION, REMOVE]
      else [REMOVE]
      end
    end
  end
end
