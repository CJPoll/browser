# frozen_string_literal: true

module Domain
  # The tabs a window had open, and which one the user was looking at.
  #
  # Saved when the window closes and read back when the next one opens. The
  # snapshot is what decides *which* tabs are worth restoring: a tab that has
  # no URI (one that never finished loading) is dropped rather than invented,
  # and the selection moves with the tabs that survive.
  class SessionSnapshot
    TABS_KEY = 'tabs'
    CURRENT_TAB_INDEX_KEY = 'current_tab_index'

    attr_reader :tab_urls, :current_tab_index

    # @param tab_urls [Array<String>] URLs to reopen, in tab order
    # @param current_tab_index [Integer] Index of the tab to select
    def initialize(tab_urls:, current_tab_index:)
      raise ArgumentError, 'tab_urls is required' if tab_urls.nil?
      raise ArgumentError, 'current_tab_index is required' if current_tab_index.nil?

      @tab_urls = tab_urls.freeze
      @current_tab_index = current_tab_index
      freeze
    end

    # Builds the snapshot for a window that is closing
    #
    # @param tab_uris [Array<String, nil>] Each tab's URI, in tab order
    # @param current_tab_index [Integer, nil] Index of the active tab
    # @return [Domain::SessionSnapshot]
    def self.build(tab_uris, current_tab_index)
      uris = Array(tab_uris)
      kept = uris.select { |uri| present?(uri) }
      selected = uris.first(current_tab_index.to_i).count { |uri| present?(uri) }

      new(tab_urls: kept, current_tab_index: clamp_index(selected, kept))
    end

    # Reads a snapshot back from the saved session
    #
    # @param hash [Hash, nil] Parsed session file contents
    # @return [Domain::SessionSnapshot, nil] nil when there is nothing to restore
    def self.from_h(hash)
      return nil unless hash.is_a?(Hash)

      urls = Array(hash[TABS_KEY]).select { |url| present?(url) }
      return nil if urls.empty?

      requested = hash[CURRENT_TAB_INDEX_KEY]
      requested = 0 unless requested.is_a?(Integer) && requested >= 0

      new(tab_urls: urls, current_tab_index: clamp_index(requested, urls))
    end

    # @return [Boolean] Whether there is anything to restore
    def empty?
      tab_urls.empty?
    end

    # @return [Hash] The session file contents
    def to_h
      { TABS_KEY => tab_urls, CURRENT_TAB_INDEX_KEY => current_tab_index }
    end

    def ==(other)
      other.is_a?(SessionSnapshot) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    # @param url [String, nil] A tab URI
    # @return [Boolean] Whether the tab is worth restoring
    def self.present?(url)
      !url.nil? && !url.to_s.strip.empty?
    end
    private_class_method :present?

    # @param index [Integer] Desired selection
    # @param urls [Array<String>] Tabs that survived
    # @return [Integer] A selection that names one of them
    def self.clamp_index(index, urls)
      return 0 if urls.empty?

      [index, urls.length - 1].min
    end
    private_class_method :clamp_index
  end
end
