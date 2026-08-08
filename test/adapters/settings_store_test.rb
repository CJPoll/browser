require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../lib/adapters/settings_store'

class AdaptersSettingsStoreTest < Minitest::Test
  def setup
    @data_dir = Dir.mktmpdir('settings-store-test')
    @store = Adapters::SettingsStore.new(data_dir: @data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && Dir.exist?(@data_dir)
  end

  def settings_file
    File.join(@data_dir, 'settings.json')
  end

  def test_saves_settings_as_json
    @store.save('dark_mode' => true)

    assert_equal({ 'dark_mode' => true }, JSON.parse(File.read(settings_file)))
  end

  def test_loads_the_settings_that_were_saved
    @store.save('dark_mode' => true)

    assert_equal({ 'dark_mode' => true }, @store.load)
  end

  # Unlike the session, settings survive being read.
  def test_loading_leaves_the_settings_in_place
    @store.save('dark_mode' => true)
    @store.load

    assert_equal({ 'dark_mode' => true }, @store.load)
  end

  def test_loads_an_empty_settings_hash_on_first_run
    assert_equal({}, @store.load)
  end

  def test_saving_replaces_the_previous_settings
    @store.save('dark_mode' => true)
    @store.save('dark_mode' => false)

    assert_equal({ 'dark_mode' => false }, @store.load)
  end

  def test_creates_its_directory_if_the_browser_has_never_run
    nested = File.join(@data_dir, 'never', 'used')
    Adapters::SettingsStore.new(data_dir: nested).save('dark_mode' => true)

    assert File.exist?(File.join(nested, 'settings.json'))
  end

  # === Failure paths ===

  def test_a_corrupt_settings_file_is_reported_and_falls_back_to_defaults
    File.write(settings_file, 'not json{')

    result = nil
    _out, err = capture_io { result = @store.load }

    assert_equal({}, result)
    assert_includes err, 'Failed to load settings'
  end

  def test_an_unwritable_location_is_reported_rather_than_raised
    store = Adapters::SettingsStore.new(data_dir: @data_dir)
    FileUtils.chmod(0o500, @data_dir)

    result = nil
    _out, err = capture_io { result = store.save('dark_mode' => true) }

    assert_equal false, result
    assert_includes err, 'Failed to save settings'
  ensure
    FileUtils.chmod(0o700, @data_dir)
  end

  def test_saving_reports_success
    assert_equal true, @store.save('dark_mode' => true)
  end
end
