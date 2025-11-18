require 'minitest/autorun'
require 'minitest/assertions'
require 'tempfile'
require 'fileutils'
require 'gtk3'

# Load the application code
require_relative '../queue_manager'
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
end

# Include in all tests
class Minitest::Test
  include TestHelpers
end
