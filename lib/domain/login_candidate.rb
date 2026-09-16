# frozen_string_literal: true

module Domain
  # A 1Password Login item as it appears in a listing: the ids needed to fetch
  # it, its title, the stored username, and the URLs it is associated with.
  #
  # It deliberately has no password: a listing (`op item list`) never returns
  # field values, and the secret is fetched separately, later, and lives only
  # in Domain::LoginCredential.
  class LoginCandidate
    attr_reader :item_id, :vault_id, :title, :username, :urls

    # @param item_id [String] required, non-empty
    # @param vault_id [String] required, non-empty
    # @param title [String] required, non-empty
    # @param username [String, nil]
    # @param urls [Array<String>]
    def initialize(item_id:, vault_id:, title:, username: nil, urls: [])
      @item_id = require_present(item_id, :item_id)
      @vault_id = require_present(vault_id, :vault_id)
      @title = require_present(title, :title)
      @username = username
      @urls = Array(urls).dup.freeze
      freeze
    end

    # @return [String] title plus the username in parentheses, or just the
    #   title when there is no username
    def label
      username.nil? || username.empty? ? title : "#{title} (#{username})"
    end

    # @return [Hash] every attribute
    def to_h
      { item_id: item_id, vault_id: vault_id, title: title, username: username, urls: urls }
    end

    # @param overrides [Hash]
    # @return [LoginCandidate] a copy with the given attributes replaced
    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def require_present(value, name)
      raise ArgumentError, "#{name} is required" if value.nil? || value.to_s.empty?

      value
    end
  end
end
