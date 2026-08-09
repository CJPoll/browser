require 'fileutils'

# Manages WebKit2GTK web context creation and configuration
class WebContextManager
  # Creates and configures a WebKit2GTK web context with:
  # - Persistent cookie storage (SQLite)
  # - Favicon database
  # - Local storage and IndexedDB directories
  #
  # @param data_dir [String] Base directory for browser data (default: ~/.local/share/toy-browser)
  # @param cache_dir [String] Base directory for cache (default: ~/.cache/toy-browser)
  # @return [WebKit2Gtk::WebContext] Configured web context
  def self.create(data_dir: nil, cache_dir: nil)
    data_dir ||= File.join(Dir.home, '.local/share/toy-browser')
    cache_dir ||= File.join(Dir.home, '.cache/toy-browser')

    FileUtils.mkdir_p(data_dir)
    FileUtils.mkdir_p(cache_dir)

    # Get the default web context
    context = WebKit2Gtk::WebContext.default

    # Set up persistent cookie storage
    cookies_file = File.join(data_dir, 'cookies.sqlite')
    cookie_manager = context.cookie_manager
    cookie_manager.set_persistent_storage(
      cookies_file,
      :sqlite
    )

    # Set up favicon database
    favicon_dir = File.join(data_dir, 'favicons')
    FileUtils.mkdir_p(favicon_dir)
    context.set_favicon_database_directory(favicon_dir)

    context
  end
end
