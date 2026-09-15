# frozen_string_literal: true

require 'gobject-introspection'

# The JavaScriptCore bindings, loaded from the system typelib.
#
# A WebKit script message arrives as a `JSCValue`, and the webkit2-gtk gem
# does not load the JavaScriptCore namespace that gives it `#to_s` (there is
# no javascriptcore-gtk gem on rubygems). Loading the typelib through
# gobject-introspection binds the same GObject class the gem already hands
# over, so `result.js_value.to_s` becomes the message text.
#
# Framework: it exists only to talk to WebKit.
module JavaScriptCore
  TYPELIB_VERSION = '4.1'

  class << self
    # Binds the namespace once; later calls are no-ops.
    #
    # @return [void]
    def load_bindings
      return if @loaded

      loader = GObjectIntrospection::Loader.new(self)
      loader.version = TYPELIB_VERSION
      loader.load('JavaScriptCore')
      @loaded = true
    end
  end
end

JavaScriptCore.load_bindings
