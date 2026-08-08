require 'minitest/autorun'
require 'minitest/assertions'

# Custom reporter that stops after N failures
module Minitest
  class FailAfterThresholdReporter < Reporter
    FAILURE_THRESHOLD = 3

    def initialize(io = $stdout, options = {})
      super
      @failure_count = 0
    end

    def record(result)
      failures = result.failures.reject { |f| f.is_a?(Minitest::Skip) }
      if failures.any?
        @failure_count += 1
        if @failure_count >= FAILURE_THRESHOLD
          io.puts
          io.puts "Stopping after #{FAILURE_THRESHOLD} failures."
          raise Interrupt
        end
      end
    end
  end

  # Plugin hooks for Minitest
  def self.plugin_fail_after_threshold_init(options)
    self.reporter.reporters << FailAfterThresholdReporter.new(options[:io], options)
  end

  # Register the plugin
  extensions << 'fail_after_threshold'
end
require 'tempfile'
require 'fileutils'
require 'gtk3'

# Load the application code
require_relative '../lib/repositories/queue_database'
require_relative '../lib/managers/queue_manager'
require_relative '../lib/managers/queue_navigation_manager'
require_relative '../lib/managers/queue_metadata_worker'
require_relative '../lib/ui/queue_list_view'
require_relative '../lib/ui/tag_edit_dialog'

# Make sure we have all assertion methods available
module Minitest::Assertions
  # assert_not_nil is an alias for assert(!(value.nil?), message)
  def assert_not_nil(value, message = nil)
    message ||= "Expected #{value.inspect} to not be nil"
    assert !(value.nil?), message
  end

  # assert_not_includes is for checking if collection doesn't include value
  def assert_not_includes(collection, value, message = nil)
    message ||= "Expected #{collection.inspect} to not include #{value.inspect}"
    assert !collection.include?(value), message
  end
end

# Test helper utilities
module TestHelpers
  # Creates a stub key event for keyboard handler testing
  # @param keyval [Integer] Gdk keyval constant (e.g., Gdk::Keyval::KEY_t)
  # @param control [Boolean] Control key pressed
  # @param alt [Boolean] Alt key pressed (mod1_mask)
  # @param shift [Boolean] Shift key pressed
  # @return [Object] Stub event object with keyval and state methods
  def create_key_event(keyval, control: false, alt: false, shift: false)
    event = Object.new
    state = Object.new

    event.define_singleton_method(:keyval) { keyval }
    event.define_singleton_method(:state) { state }

    state.define_singleton_method(:control_mask?) { control }
    state.define_singleton_method(:mod1_mask?) { alt }
    state.define_singleton_method(:shift_mask?) { shift }

    event
  end

  # Creates a dummy favicon image creator proc for testing
  # @return [Proc] Proc that returns empty Gtk::Image
  def create_favicon_creator
    ->(favicon_data) { Gtk::Image.new }
  end

  # Builds a queue manager backed by a real SQLite file.
  #
  # These are widget tests, not manager tests, so they use the real stack
  # rather than mocks -- the queue is what the widget renders. Close it in
  # teardown with `@queue_manager.close`.
  #
  # @param db_path [String] Path to a temporary SQLite file
  # @return [Managers::QueueManager]
  def create_queue_manager(db_path)
    Managers::QueueManager.new(database: Repositories::QueueDatabase.new(db_path: db_path))
  end

  # Builds a queue list view wired to a queue manager.
  #
  # The widget itself holds no manager -- it takes data sources and intents.
  # This helper plays the part `BrowserWindow` plays in production and binds
  # them, so a widget test can drive the real queue without the callback
  # boilerplate appearing in every setup.
  #
  # @param queue_manager [Managers::QueueManager]
  # @return [QueueListView]
  def create_queue_list_view(queue_manager)
    QueueListView.new(**queue_list_view_callbacks(queue_manager))
  end

  # The bindings `create_queue_list_view` uses, exposed so a test can override
  # one of them (e.g. to count how often a data source is consulted).
  #
  # @param queue_manager [Managers::QueueManager]
  # @return [Hash] Callback hash for QueueListView
  def queue_list_view_callbacks(queue_manager)
    {
      create_favicon_image: create_favicon_creator,
      get_entries: ->(tag_ids) { queue_manager.entries_for_filter(tag_ids) },
      get_total_count: -> { queue_manager.count },
      get_tags_for_entry: ->(entry_id) { queue_manager.tags_for_entry(entry_id) },
      get_tag_usages: -> { queue_manager.tag_usage_counts },
      find_tag_by_name: ->(tag_name) { queue_manager.find_tag_by_name(tag_name) },
      find_tag_by_id: ->(tag_id) { queue_manager.find_tag_by_id(tag_id) },
      on_remove_entry: ->(entry_id) { queue_manager.remove_by_id(entry_id) },
      on_move_entry: ->(entry_id, position) { queue_manager.move(entry_id, position) }
    }
  end

  # The bindings a tag edit dialog needs, played by this helper rather than
  # `BrowserWindow`. Merge in `on_tags_changed:`/`on_error:` per test.
  #
  # @param queue_manager [Managers::QueueManager]
  # @return [Hash] Callback hash for TagEditDialog
  def tag_edit_dialog_callbacks(queue_manager)
    {
      get_all_tags: -> { queue_manager.all_tags },
      get_assigned_tag_ids: ->(entry_id) { queue_manager.tags_for_entry(entry_id).map(&:id) },
      on_assign_tag: ->(entry_id, tag_id) { queue_manager.assign_tag(entry_id, tag_id) },
      on_unassign_tag: ->(entry_id, tag_id) { queue_manager.unassign_tag(entry_id, tag_id) },
      on_create_tag: ->(tag_name) { queue_manager.create_or_find_tag(tag_name) }
    }
  end

  # The bindings a history list view needs, played by this helper rather than
  # `BrowserWindow`.
  #
  # @param history_manager [Managers::HistoryManager]
  # @return [Hash] Callback hash for HistoryListView
  def history_list_view_callbacks(history_manager)
    {
      create_favicon_image: create_favicon_creator,
      get_search_results: ->(query, limit) { history_manager.search(query, limit) },
      get_recent_visits: ->(limit) { history_manager.recent_visits(limit) },
      on_delete_visit: ->(visit_id) { history_manager.delete_visit(visit_id) }
    }
  end
end

# Include in all tests
class Minitest::Test
  include TestHelpers
end
