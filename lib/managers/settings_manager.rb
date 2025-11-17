require 'json'
require 'fileutils'

# Manages persistent browser settings (dark mode, etc.)
class SettingsManager
  attr_accessor :dark_mode

  # @param data_dir [String] Directory where settings.json is stored
  def initialize(data_dir: nil)
    @data_dir = data_dir || File.join(Dir.home, '.local/share/toy-browser')
    @settings_file = File.join(@data_dir, 'settings.json')

    FileUtils.mkdir_p(@data_dir)

    # Default settings
    @dark_mode = false

    load_settings
  end

  # Load settings from disk
  # @return [void]
  def load_settings
    if File.exist?(@settings_file)
      begin
        settings = JSON.parse(File.read(@settings_file))
        @dark_mode = settings['dark_mode'] || false
      rescue => e
        puts "Failed to load settings: #{e.message}"
      end
    end
  end

  # Save settings to disk
  # @return [void]
  def save_settings
    settings = {
      'dark_mode' => @dark_mode
    }

    begin
      File.write(@settings_file, JSON.pretty_generate(settings))
    rescue => e
      puts "Failed to save settings: #{e.message}"
    end
  end

  # Toggle dark mode setting
  # @return [Boolean] New dark mode value
  def toggle_dark_mode
    @dark_mode = !@dark_mode
    @dark_mode
  end
end
