require 'minitest/autorun'
require 'json'
require_relative '../../lib/adapters/one_password_passkey_store'
require_relative '../../lib/domain/passkey'
require_relative '../../lib/domain/base64url'

class AdaptersOnePasswordPasskeyStoreTest < Minitest::Test
  CREATED_AT = Time.utc(2026, 9, 14, 12, 0, 0).freeze
  PEM = "-----BEGIN PRIVATE KEY-----\nMIGH\n-----END PRIVATE KEY-----\n".freeze

  # Answers each invocation with the next canned result and records the argv.
  class RecordingRunner
    Status = Struct.new(:success?)

    attr_reader :invocations

    def initialize(results = [])
      @results = results
      @invocations = []
    end

    def call(*argv)
      @invocations << argv
      stdout, stderr, success = @results.shift || ['', '', true]
      [stdout, stderr, Status.new(success)]
    end
  end

  def passkey(**overrides)
    Domain::Passkey.new(**{
      credential_id: 'Y3JlZC0x', rp_id: 'example.com', user_handle: 'dXNlci0x',
      user_name: 'cody@example.com', user_display_name: 'Cody',
      private_key_pem: PEM, created_at: CREATED_AT
    }.merge(overrides))
  end

  def item_json(id:, rp_id: 'example.com', fields: {})
    values = {
      'credential_id' => 'Y3JlZC0x', 'rp_id' => rp_id, 'user_handle' => 'dXNlci0x',
      'user_name' => 'cody@example.com', 'user_display_name' => 'Cody',
      'private_key' => Domain::Base64Url.encode(PEM), 'created_at' => '2026-09-14T12:00:00Z'
    }.merge(fields)
    JSON.generate(
      'id' => id, 'title' => "Passkey: #{rp_id} (Cody)",
      'urls' => [{ 'href' => "https://#{rp_id}" }],
      'fields' => values.map { |label, value| { 'label' => label, 'value' => value, 'section' => { 'label' => 'passkey' } } }
    )
  end

  def list_json(*items)
    JSON.generate(items.map { |id, rp_id| { 'id' => id, 'urls' => [{ 'href' => "https://#{rp_id}" }] } })
  end

  def store_with(*results)
    @runner = RecordingRunner.new(results)
    Adapters::OnePasswordPasskeyStore.new(runner: @runner)
  end

  # --- save ---

  def test_save_creates_a_tagged_secure_note_for_the_site
    store = store_with([JSON.generate('id' => 'item-1'), '', true])

    store.save(passkey)

    argv = @runner.invocations.first
    assert_equal %w[op item create], argv.first(3)
    assert_includes_pair argv, '--category', 'Secure Note'
    assert_includes_pair argv, '--title', 'Passkey: example.com (Cody)'
    assert_includes_pair argv, '--tags', 'toy-browser-passkey'
    assert_includes_pair argv, '--url', 'https://example.com'
    assert_includes_pair argv, '--format', 'json'
  end

  def test_save_writes_every_attribute_as_a_field_in_the_passkey_section
    store = store_with([JSON.generate('id' => 'item-1'), '', true])

    store.save(passkey)

    argv = @runner.invocations.first
    assert_includes argv, 'passkey.credential_id[text]=Y3JlZC0x'
    assert_includes argv, 'passkey.rp_id[text]=example.com'
    assert_includes argv, 'passkey.user_handle[text]=dXNlci0x'
    assert_includes argv, 'passkey.user_name[text]=cody@example.com'
    assert_includes argv, 'passkey.user_display_name[text]=Cody'
    assert_includes argv, 'passkey.created_at[text]=2026-09-14T12:00:00Z'
  end

  def test_save_conceals_the_private_key_as_a_single_line
    # base64url keeps the PEM's newlines out of the argument and marks the
    # field concealed so 1Password hides it.
    store = store_with([JSON.generate('id' => 'item-1'), '', true])

    store.save(passkey)

    assert_includes @runner.invocations.first, "passkey.private_key[concealed]=#{Domain::Base64Url.encode(PEM)}"
  end

  def test_save_returns_the_passkey_with_the_item_id
    store = store_with([JSON.generate('id' => 'item-1'), '', true])

    saved = store.save(passkey)

    assert_equal 'item-1', saved.store_id
    assert_equal passkey.with(store_id: 'item-1'), saved
  end

  def test_save_passes_page_supplied_text_as_data_not_shell
    store = store_with([JSON.generate('id' => 'item-1'), '', true])

    store.save(passkey(user_display_name: '$(whoami)'))

    argv = @runner.invocations.first
    assert_includes argv, 'passkey.user_display_name[text]=$(whoami)'
    assert_includes_pair argv, '--title', 'Passkey: example.com ($(whoami))'
  end

  def test_save_reports_a_failed_op_with_its_error
    store = store_with(['', '[ERROR] You are not currently signed in', false])

    error = assert_raises(Adapters::OnePasswordPasskeyStore::Unavailable) { store.save(passkey) }

    assert_match(/not currently signed in/, error.message)
  end

  # --- find_for_rp ---

  def test_find_for_rp_lists_by_tag_then_reads_each_matching_item_revealed
    store = store_with(
      [list_json(%w[item-1 example.com]), '', true],
      [item_json(id: 'item-1'), '', true]
    )

    store.find_for_rp('example.com')

    assert_equal ['op', 'item', 'list', '--tags', 'toy-browser-passkey', '--format', 'json'], @runner.invocations[0]
    assert_equal ['op', 'item', 'get', 'item-1', '--format', 'json', '--reveal'], @runner.invocations[1]
  end

  def test_find_for_rp_builds_passkeys_from_the_item_fields
    store = store_with(
      [list_json(%w[item-1 example.com]), '', true],
      [item_json(id: 'item-1'), '', true]
    )

    assert_equal [passkey.with(store_id: 'item-1')], store.find_for_rp('example.com')
  end

  def test_find_for_rp_does_not_read_items_for_other_sites
    store = store_with(
      [list_json(%w[item-1 example.com], %w[item-2 other.example]), '', true],
      [item_json(id: 'item-1'), '', true]
    )

    found = store.find_for_rp('example.com')

    assert_equal ['item-1'], found.map(&:store_id)
    assert_equal 2, @runner.invocations.length
  end

  def test_find_for_rp_is_empty_when_nothing_is_stored
    store = store_with([list_json, '', true])

    assert_empty store.find_for_rp('example.com')
  end

  def test_find_for_rp_skips_an_item_missing_its_private_key_and_warns
    store = store_with(
      [list_json(%w[item-1 example.com]), '', true],
      [item_json(id: 'item-1', fields: { 'private_key' => nil }), '', true]
    )

    found = nil
    assert_output(nil, /item-1/) { found = store.find_for_rp('example.com') }

    assert_empty found
  end

  def test_find_for_rp_reports_a_failed_op_with_its_error
    store = store_with(['', '[ERROR] You are not currently signed in', false])

    assert_raises(Adapters::OnePasswordPasskeyStore::Unavailable) { store.find_for_rp('example.com') }
  end

  private

  def assert_includes_pair(argv, flag, value)
    index = argv.index(flag)
    refute_nil index, "expected #{flag} in #{argv.inspect}"
    assert_equal value, argv[index + 1]
  end
end
