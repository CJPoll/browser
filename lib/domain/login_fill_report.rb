# frozen_string_literal: true

require 'json'

module Domain
  # What the page's fill script reported: whether the fields were filled and,
  # if not, why. `parse` never raises and never puts the input text into any
  # message -- a malformed body reads as "not filled, unreadable report".
  class LoginFillReport
    UNREADABLE = :unreadable_report

    # @param json [String, nil]
    # @return [LoginFillReport]
    def self.parse(json)
      data = JSON.parse(json)
      return unreadable unless data.is_a?(Hash)

      new(
        filled: data['ok'] == true,
        username_filled: data['username'] == true,
        reason: data['reason'] ? data['reason'].to_s.to_sym : nil
      )
    rescue JSON::ParserError, TypeError
      unreadable
    end

    def self.unreadable
      new(filled: false, username_filled: false, reason: UNREADABLE)
    end
    private_class_method :unreadable

    attr_reader :reason

    def initialize(filled:, username_filled:, reason:)
      @filled = filled
      @username_filled = username_filled
      @reason = reason
      freeze
    end

    def filled?
      @filled
    end

    def username_filled?
      @username_filled
    end
  end
end
