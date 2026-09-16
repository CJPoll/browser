# frozen_string_literal: true

require 'json'

module Domain
  # What the page's probe script reported: whether this is the top document,
  # its origin, and whether it has a fillable password/username field.
  #
  # `parse` never raises: a malformed, empty or non-object body reads as "no
  # form", so the manager treats a broken probe the same as a page with no
  # login (deny by default).
  class LoginFormProbe
    # @param json [String, nil]
    # @return [LoginFormProbe]
    def self.parse(json)
      data = JSON.parse(json)
      new(data.is_a?(Hash) ? data : {})
    rescue JSON::ParserError, TypeError
      new({})
    end

    # @param data [Hash]
    def initialize(data)
      @data = data
      freeze
    end

    def top?
      @data['top'] == true
    end

    def origin
      @data['origin']
    end

    def password_field?
      @data['password'] == true
    end

    def username_field?
      @data['username'] == true
    end
  end
end
