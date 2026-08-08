# frozen_string_literal: true

module Domain
  # DownloadBadge derives the toolbar download indicator from a set of
  # downloads.
  #
  # Pure: it reads no clock, no database and no widget -- callers pass the
  # downloads in and act on the returned symbol.
  module DownloadBadge
    # Badge state for a collection of downloads
    #
    # Finished downloads (completed, failed, cancelled) are ignored: the badge
    # reports only on transfers still in flight.
    #
    # @param downloads [Array<Download>] Downloads in any state
    # @return [Symbol] :none, :paused, or :active
    def self.state(downloads)
      active = downloads.select(&:active?)

      return :none if active.empty?
      return :paused if active.any? { |download| download.state == :paused }

      :active
    end

    # Number of downloads still in flight
    #
    # @param downloads [Array<Download>] Downloads in any state
    # @return [Integer] Count of active downloads
    def self.count(downloads)
      downloads.count(&:active?)
    end
  end
end
