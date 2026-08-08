require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../lib/adapters/session_store'

class AdaptersSessionStoreTest < Minitest::Test
  SESSION = { 'tabs' => ['https://a.example', 'https://b.example'], 'current_tab_index' => 1 }.freeze

  def setup
    @data_dir = Dir.mktmpdir('session-store-test')
    @store = Adapters::SessionStore.new(data_dir: @data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && Dir.exist?(@data_dir)
  end

  def session_file
    File.join(@data_dir, 'session.json')
  end

  def test_saves_the_session_as_json
    @store.save(SESSION)

    assert_equal SESSION, JSON.parse(File.read(session_file))
  end

  def test_loads_the_session_that_was_saved
    @store.save(SESSION)

    assert_equal SESSION, @store.load
  end

  # The session is a hand-off, not an archive: once the window has taken it,
  # a crash later in the run must not restore stale tabs.
  def test_loading_consumes_the_session
    @store.save(SESSION)
    @store.load

    refute File.exist?(session_file)
    assert_nil @store.load
  end

  def test_loads_nothing_when_no_session_was_saved
    assert_nil @store.load
  end

  def test_saving_replaces_the_previous_session
    @store.save(SESSION)
    @store.save('tabs' => ['https://c.example'], 'current_tab_index' => 0)

    assert_equal ['https://c.example'], @store.load['tabs']
  end

  def test_creates_its_directory_if_the_browser_has_never_run
    nested = File.join(@data_dir, 'never', 'used')
    Adapters::SessionStore.new(data_dir: nested).save(SESSION)

    assert File.exist?(File.join(nested, 'session.json'))
  end

  # === Failure paths ===

  def test_a_corrupt_session_file_is_reported_and_ignored
    File.write(session_file, 'not json{')

    result = nil
    _out, err = capture_io { result = @store.load }

    assert_nil result
    assert_includes err, 'Failed to load session'
  end

  def test_an_unwritable_location_is_reported_rather_than_raised
    store = Adapters::SessionStore.new(data_dir: @data_dir)
    FileUtils.chmod(0o500, @data_dir)

    result = nil
    _out, err = capture_io { result = store.save(SESSION) }

    assert_equal false, result
    assert_includes err, 'Failed to save session'
  ensure
    FileUtils.chmod(0o700, @data_dir)
  end

  def test_saving_reports_success
    assert_equal true, @store.save(SESSION)
  end
end
