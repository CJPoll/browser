# frozen_string_literal: true

module Domain
  # Why nothing was filled, in words the user can act on. Shown in the bar in
  # place of a prompt. A reason outside REASONS is a programming error, not a
  # user-facing state, so it raises.
  class LoginFillNotice
    # Reasons whose message is fixed. `:no_matches`, `:unavailable` and
    # `:fill_failed` build their message from `detail` in #message instead.
    FIXED_MESSAGES = {
      no_origin: 'Login fill needs an http(s) page to match against',
      insecure_origin: 'Login fill is only offered on https pages (or localhost)',
      no_login_form: 'No password field was found on this page',
      not_installed: 'The 1Password CLI (op) is not installed',
      not_signed_in: '1Password is locked: run op signin in a terminal, then try again',
      timed_out: '1Password did not answer in time',
      origin_changed: 'The page changed before the login was filled; nothing was filled'
    }.freeze

    REASONS = (FIXED_MESSAGES.keys + %i[no_matches unavailable fill_failed]).freeze

    attr_reader :reason, :detail

    # @param reason [Symbol] one of REASONS
    # @param detail [String, nil]
    def initialize(reason:, detail: nil)
      raise ArgumentError, "unknown reason #{reason.inspect}" unless REASONS.include?(reason)

      @reason = reason
      @detail = detail
      freeze
    end

    # @return [String]
    def message
      case reason
      when :no_matches then "No 1Password login matches #{detail}"
      when :unavailable then "1Password is unavailable: #{detail}"
      when :fill_failed then "The login could not be filled (#{detail})"
      else FIXED_MESSAGES.fetch(reason)
      end
    end

    # @return [Hash]
    def to_h
      { reason: reason, detail: detail }
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
