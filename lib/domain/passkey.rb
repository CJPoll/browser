# frozen_string_literal: true

module Domain
  # A passkey this browser created: the credential the site knows it by, the
  # relying party it is scoped to, the account it belongs to, and the private
  # key that proves it.
  #
  # The private key is carried as PEM text because that is what the store
  # keeps and the signer reads; nothing here interprets it.
  #
  # `sign_count` is always zero. Synced passkey providers report a constant
  # counter, and relying parties treat a counter that goes backwards as a
  # cloned key -- which is exactly what a counter kept in a store this browser
  # cannot update atomically would look like.
  class Passkey
    SIGN_COUNT = 0

    attr_reader :credential_id, :rp_id, :user_handle, :user_name,
                :user_display_name, :private_key_pem, :created_at, :store_id

    # @param credential_id [String] base64url credential ID the site was given
    # @param rp_id [String] Relying-party ID the key is scoped to
    # @param user_handle [String] base64url user handle the site supplied
    # @param private_key_pem [String] PEM-encoded ES256 private key
    # @param created_at [Time] When the key was made (supplied by the manager)
    # @param user_name [String, nil] Account name, usually an email address
    # @param user_display_name [String, nil] Human-readable account name
    # @param store_id [String, nil] The store's own identifier, once saved
    def initialize(credential_id:, rp_id:, user_handle:, private_key_pem:, created_at:,
                   user_name: nil, user_display_name: nil, store_id: nil)
      raise ArgumentError, 'credential_id is required' if blank?(credential_id)
      raise ArgumentError, 'rp_id is required' if blank?(rp_id)
      raise ArgumentError, 'user_handle is required' if blank?(user_handle)
      raise ArgumentError, 'private_key_pem is required' if blank?(private_key_pem)
      raise ArgumentError, 'created_at is required' if created_at.nil?

      @credential_id = credential_id
      @rp_id = rp_id
      @user_handle = user_handle
      @user_name = user_name
      @user_display_name = user_display_name
      @private_key_pem = private_key_pem
      @created_at = created_at
      @store_id = store_id
      freeze
    end

    # @return [Integer] Always SIGN_COUNT; see the class comment
    def sign_count
      SIGN_COUNT
    end

    # @return [String] The name to show for this passkey's account
    def user_label
      [user_display_name, user_name].find { |value| !blank?(value) } || rp_id
    end

    # @param overrides [Hash] Attributes to change
    # @return [Passkey] A copy with the overrides applied
    def with(**overrides)
      self.class.new(**to_h.reject { |key, _| key == :sign_count }.merge(overrides))
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        credential_id: credential_id, rp_id: rp_id, user_handle: user_handle,
        user_name: user_name, user_display_name: user_display_name,
        private_key_pem: private_key_pem, sign_count: sign_count,
        created_at: created_at, store_id: store_id
      }
    end

    def ==(other)
      other.is_a?(Passkey) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
