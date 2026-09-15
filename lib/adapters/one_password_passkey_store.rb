# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'
require_relative '../domain/passkey'
require_relative '../domain/base64url'

module Adapters
  # Keeps the browser's passkeys in 1Password, one Secure Note per passkey,
  # through the `op` command-line tool.
  #
  # 1Password's own passkeys cannot be read from outside its app, so these
  # are ordinary items with the private key in a concealed field. They are
  # tagged so they can be listed, and carry the relying party as a URL so the
  # listing (which returns no fields) can be filtered before each item is
  # fetched with its secrets revealed.
  #
  # Follows the shell-out conventions in lib/adapters/CLAUDE.md: argv, never
  # a shell string, and an injected runner. The runner here captures output,
  # so it answers `[stdout, stderr, status]`.
  class OnePasswordPasskeyStore
    # `op` failed: not signed in, no such vault, no network.
    class Unavailable < StandardError; end

    COMMAND = 'op'
    CATEGORY = 'Secure Note'
    TAG = 'toy-browser-passkey'
    SECTION = 'passkey'
    JSON_FORMAT = %w[--format json].freeze

    CAPTURE_RUNNER = ->(*argv) { Open3.capture3(*argv) }

    # @param runner [#call] Receives argv, answers `[stdout, stderr, status]`
    def initialize(runner: CAPTURE_RUNNER)
      @runner = runner
    end

    # Creates a 1Password item for a passkey
    #
    # @param passkey [Domain::Passkey]
    # @return [Domain::Passkey] The same passkey with its `store_id` set
    # @raise [Unavailable] If `op` fails
    def save(passkey)
      output = run(COMMAND, 'item', 'create',
                   '--category', CATEGORY,
                   '--title', title_for(passkey),
                   '--tags', TAG,
                   '--url', url_for(passkey.rp_id),
                   *JSON_FORMAT,
                   *field_assignments(passkey))
      passkey.with(store_id: JSON.parse(output)['id'])
    end

    # Every passkey stored for a relying party
    #
    # @param rp_id [String]
    # @return [Array<Domain::Passkey>]
    # @raise [Unavailable] If `op` fails
    def find_for_rp(rp_id)
      items = JSON.parse(run(COMMAND, 'item', 'list', '--tags', TAG, *JSON_FORMAT))
      items.select { |item| Array(item['urls']).any? { |url| url['href'] == url_for(rp_id) } }
           .filter_map { |item| build_passkey(fetch(item['id'])) }
    end

    private

    def fetch(item_id)
      JSON.parse(run(COMMAND, 'item', 'get', item_id, *JSON_FORMAT, '--reveal'))
    end

    def run(*argv)
      stdout, stderr, status = @runner.call(*argv)
      raise Unavailable, stderr.to_s.strip unless status.success?

      stdout
    end

    def title_for(passkey)
      "Passkey: #{passkey.rp_id} (#{passkey.user_label})"
    end

    def url_for(rp_id)
      "https://#{rp_id}"
    end

    # `op`'s field assignment syntax: `section.label[type]=value`. The PEM is
    # base64url-encoded so its newlines never reach an argument.
    def field_assignments(passkey)
      [
        text_field('credential_id', passkey.credential_id),
        text_field('rp_id', passkey.rp_id),
        text_field('user_handle', passkey.user_handle),
        text_field('user_name', passkey.user_name),
        text_field('user_display_name', passkey.user_display_name),
        text_field('created_at', passkey.created_at.utc.iso8601),
        "#{SECTION}.private_key[concealed]=#{Domain::Base64Url.encode(passkey.private_key_pem)}"
      ]
    end

    def text_field(label, value)
      "#{SECTION}.#{label}[text]=#{value}"
    end

    # @param item [Hash] An `op item get` result
    # @return [Domain::Passkey, nil] nil (with a warning) if the item has
    #   been edited into something that is no longer a passkey
    def build_passkey(item)
      fields = Array(item['fields']).to_h { |field| [field['label'], field['value']] }

      Domain::Passkey.new(
        credential_id: fields['credential_id'],
        rp_id: fields['rp_id'],
        user_handle: fields['user_handle'],
        user_name: fields['user_name'],
        user_display_name: fields['user_display_name'],
        private_key_pem: fields['private_key'] && Domain::Base64Url.decode(fields['private_key']),
        created_at: fields['created_at'] && Time.iso8601(fields['created_at']),
        store_id: item['id']
      )
    rescue ArgumentError => e
      warn "Ignoring 1Password item #{item['id']}: #{e.message}"
      nil
    end
  end
end
