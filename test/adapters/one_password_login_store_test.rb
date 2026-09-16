# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../lib/adapters/one_password_login_store'
require_relative '../../lib/adapters/one_password_cli'
require_relative '../../lib/domain/login_candidate'

class AdaptersOnePasswordLoginStoreTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'

  # Records the argv (including 'op') and answers with canned results, so the
  # store is exercised over a real OnePasswordCli.
  class RecordingRunner
    Status = Struct.new(:success?)

    attr_reader :invocations

    def initialize(results = [])
      @results = results
      @invocations = []
    end

    def call(*argv, timeout:)
      @invocations << argv
      stdout, stderr, success = @results.shift || ['', '', true]
      [stdout, stderr, Status.new(success)]
    end
  end

  # The documented `op item list --categories Login --format json` shape
  # (spec 1.3), ASSUMED because `op` is not signed in on this machine.
  def item(id: 'abc123', title: 'GitHub', username: 'cody@example.com',
           vault_id: 'vlt456', urls: [{ 'href' => 'https://github.com/login' }])
    {
      'id' => id, 'title' => title, 'version' => 3,
      'vault' => { 'id' => vault_id, 'name' => 'Private' },
      'category' => 'LOGIN', 'additional_information' => username, 'urls' => urls
    }.compact
  end

  def store_with(*results)
    @runner = RecordingRunner.new(results)
    Adapters::OnePasswordLoginStore.new(cli: Adapters::OnePasswordCli.new(runner: @runner))
  end

  def candidate(item_id: 'abc123', vault_id: 'vlt456', username: 'cody@example.com')
    Domain::LoginCandidate.new(item_id: item_id, vault_id: vault_id, title: 'GitHub', username: username, urls: [])
  end

  # --- list_logins ---

  def test_list_argv
    store = store_with([JSON.generate([]), '', true])

    store.list_logins

    assert_equal %w[op item list --categories Login --format json], @runner.invocations.first
  end

  def test_list_maps_items
    store = store_with([JSON.generate([item]), '', true])

    logins = store.list_logins

    assert_equal 1, logins.length
    login = logins.first
    assert_equal 'abc123', login.item_id
    assert_equal 'vlt456', login.vault_id
    assert_equal 'GitHub', login.title
    assert_equal 'cody@example.com', login.username
    assert_equal ['https://github.com/login'], login.urls
  end

  def test_list_tolerates_missing_urls_and_additional_information
    store = store_with([JSON.generate([item(username: nil, urls: nil)]), '', true])

    login = store.list_logins.first

    assert_nil login.username
    assert_equal [], login.urls
  end

  def test_list_skips_an_item_without_an_id_and_warns
    store = store_with([JSON.generate([item(id: nil), item(id: 'keep')]), '', true])

    logins = nil
    assert_output(nil, /Ignoring 1Password item/) { logins = store.list_logins }

    assert_equal ['keep'], logins.map(&:item_id)
  end

  def test_list_with_a_non_json_body
    store = store_with(['not json at all', '', true])

    error = assert_raises(Adapters::OnePasswordCli::Failed) { store.list_logins }

    refute_includes error.message, 'not json at all'
  end

  def test_list_with_a_non_array_body
    store = store_with([JSON.generate('id' => 'x'), '', true])

    assert_raises(Adapters::OnePasswordCli::Failed) { store.list_logins }
  end

  def test_list_propagates_cli_errors
    store = store_with(['', 'You are not currently signed in', false])

    assert_raises(Adapters::OnePasswordCli::NotSignedIn) { store.list_logins }
  end

  # --- password_for ---

  def test_password_argv_carries_no_secret
    store = store_with([FAKE_PASSWORD, '', true])

    store.password_for(candidate)

    argv = @runner.invocations.first
    assert_equal ['op', 'read', '--no-newline', 'op://vlt456/abc123/password'], argv
    refute_includes argv.join(' '), FAKE_PASSWORD
  end

  def test_password_for_builds_the_credential
    store = store_with([FAKE_PASSWORD, '', true])

    credential = store.password_for(candidate)

    assert_equal FAKE_PASSWORD, credential.password
    assert_equal 'cody@example.com', credential.username
  end

  def test_password_for_with_empty_stdout
    store = store_with(['', '', true])

    assert_raises(Adapters::OnePasswordCli::Failed) { store.password_for(candidate) }
  end

  def test_password_for_prints_nothing_containing_the_secret
    store = store_with([FAKE_PASSWORD, '', true])

    out, err = capture_io { store.password_for(candidate) }

    refute_includes out, FAKE_PASSWORD
    refute_includes err, FAKE_PASSWORD
  end

  def test_password_for_failure_carries_stderr_only
    store = store_with([FAKE_PASSWORD, 'op read failed', false])

    error = assert_raises(Adapters::OnePasswordCli::Failed) { store.password_for(candidate) }

    assert_equal 'op read failed', error.message
    refute_includes error.message, FAKE_PASSWORD
  end
end
