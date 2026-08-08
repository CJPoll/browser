# frozen_string_literal: true

module Domain
  # An immutable record that a host has been granted a permission.
  #
  # The *kind* of permission (popups, camera/microphone, notifications,
  # certificate exceptions) is implied by the repository the record came from --
  # each kind has its own table. `permission_type` carries the sub-kind only
  # where one exists (media: `:audio`, `:video`, `:audio_video`).
  class HostPermission
    attr_reader :id, :host, :permission_type, :granted_at

    # @param host [String] Hostname the permission was granted to
    # @param granted_at [Time] When it was granted -- required; Domain never
    #   reads the clock, so the calling Manager supplies it
    # @param id [Integer, nil] Row id, nil until persisted
    # @param permission_type [Symbol, String, nil] Sub-kind, where the
    #   permission has one
    def initialize(host:, granted_at:, id: nil, permission_type: nil)
      raise ArgumentError, 'host is required' if host.nil? || host.to_s.empty?
      raise ArgumentError, 'granted_at is required' if granted_at.nil?

      @id = id
      @host = host
      @permission_type = permission_type&.to_sym
      @granted_at = granted_at
      freeze
    end

    # Returns a copy carrying the id assigned by the repository
    #
    # @param id [Integer] Row id
    # @return [HostPermission]
    def with_id(id)
      self.class.new(
        id: id,
        host: host,
        permission_type: permission_type,
        granted_at: granted_at
      )
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        id: id,
        host: host,
        permission_type: permission_type,
        granted_at: granted_at
      }
    end

    def ==(other)
      other.is_a?(HostPermission) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
