require 'minitest/autorun'
require 'minitest/assertions'
require 'tempfile'
require 'fileutils'

# Load the application code
require_relative '../queue_manager'

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
