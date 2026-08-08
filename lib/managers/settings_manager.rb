# frozen_string_literal: true

require_relative '../adapters/settings_store'

module Managers
  # The browser's persistent preferences.
  #
  # Holds the current values in memory so the window can read them without
  # touching disk, and writes them back through `Adapters::SettingsStore` when
  # asked. Toggling and saving are separate steps: a temporary override, like
  # zen mode dimming the chrome, must not become the stored preference.
  class SettingsManager
    DARK_MODE_KEY = 'dark_mode'

    # @return [Boolean] Whether dark mode is on
    attr_reader :dark_mode

    # @param store [Adapters::SettingsStore] Where the settings are kept
    def initialize(store: Adapters::SettingsStore.new)
      @store = store
      @dark_mode = @store.load[DARK_MODE_KEY] ? true : false
    end

    # Flips dark mode
    #
    # @return [Boolean] The new value
    def toggle_dark_mode
      @dark_mode = !@dark_mode
    end

    # Writes the current settings
    #
    # @return [Boolean] True if they were written
    def save
      @store.save(DARK_MODE_KEY => @dark_mode)
    end
  end
end
