# frozen_string_literal: true

require_relative '../adapters/session_store'
require_relative '../domain/session_snapshot'

module Managers
  # Carries a window's open tabs across a restart.
  #
  # The window hands over what its tabs currently are;
  # `Domain::SessionSnapshot` decides which of them are worth restoring and
  # which one should be selected, and `Adapters::SessionStore` holds the
  # result until the next window asks for it.
  class SessionManager
    # @param store [Adapters::SessionStore] Where the session is kept
    def initialize(store: Adapters::SessionStore.new)
      @store = store
    end

    # Saves the window's tabs for the next launch
    #
    # @param tab_uris [Array<String, nil>] Each tab's URI, in tab order
    # @param current_tab_index [Integer, nil] Index of the active tab
    # @return [Domain::SessionSnapshot] What was saved
    def save(tab_uris, current_tab_index)
      snapshot = Domain::SessionSnapshot.build(tab_uris, current_tab_index)
      @store.save(snapshot.to_h)
      snapshot
    end

    # Takes the saved session, if there is one
    #
    # The session is consumed: a second call returns nothing.
    #
    # @return [Domain::SessionSnapshot, nil] Tabs to reopen, or nil
    def restore
      Domain::SessionSnapshot.from_h(@store.load)
    end
  end
end
