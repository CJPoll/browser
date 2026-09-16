# frozen_string_literal: true

require 'json'
require_relative 'one_password_cli'
require_relative '../domain/login_candidate'
require_relative '../domain/login_credential'

module Adapters
  # Lists the user's 1Password Login items and reveals one item's password,
  # mapping `op`'s JSON to Domain objects the way a repository maps rows.
  #
  # Listing (`op item list`) never returns field values, so it exposes only
  # titles, usernames and URLs. The password is a separate `op read` by vault
  # id + item id, made as late as possible and only for a confirmed item.
  class OnePasswordLoginStore
    LIST_ARGS = %w[item list --categories Login --format json].freeze
    PASSWORD_FIELD = 'password'

    # @param cli [OnePasswordCli]
    def initialize(cli: OnePasswordCli.new)
      @cli = cli
    end

    # @return [Array<Domain::LoginCandidate>]
    # @raise [OnePasswordCli::Error]
    def list_logins
      items = JSON.parse(@cli.run(*LIST_ARGS))
      raise OnePasswordCli::Failed, 'unexpected op output' unless items.is_a?(Array)

      items.filter_map { |item| build_candidate(item) }
    rescue JSON::ParserError
      raise OnePasswordCli::Failed, 'unexpected op output'
    end

    # @param candidate [Domain::LoginCandidate]
    # @return [Domain::LoginCredential]
    # @raise [OnePasswordCli::Error]
    def password_for(candidate)
      password = @cli.run('read', '--no-newline', "op://#{candidate.vault_id}/#{candidate.item_id}/#{PASSWORD_FIELD}")
      raise OnePasswordCli::Failed, 'the item has no password' if password.nil? || password.empty?

      Domain::LoginCredential.new(username: candidate.username, password: password)
    end

    private

    # @param item [Hash] one `op item list` entry
    # @return [Domain::LoginCandidate, nil] nil (with a warning) for an item
    #   missing the ids or title a candidate needs
    def build_candidate(item)
      Domain::LoginCandidate.new(
        item_id: item['id'],
        vault_id: item.dig('vault', 'id'),
        title: item['title'],
        username: item['additional_information'],
        urls: Array(item['urls']).filter_map { |url| url['href'] }
      )
    rescue ArgumentError => e
      warn "Ignoring 1Password item #{item['id']}: #{e.message}"
      nil
    end
  end
end
