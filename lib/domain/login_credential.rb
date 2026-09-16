# frozen_string_literal: true

module Domain
  # The one secret: a username (optional) and a password, kept together only
  # long enough to hand to the fill script.
  #
  # Every printable form is redacted. `run` (the launcher) tees stdout AND
  # stderr to `logs/browser.log`, so any code path that prints this object, or
  # a string built from it, would write the password to disk. `inspect`,
  # `to_s`, `pretty_print` and `to_h` are therefore all overridden to hide it.
  class LoginCredential
    REDACTED = '#<Domain::LoginCredential (redacted)>'

    attr_reader :username, :password

    # @param username [String, nil]
    # @param password [String] required, non-empty
    def initialize(username:, password:)
      raise ArgumentError, 'password is required' unless password.is_a?(String) && !password.empty?

      @username = username
      @password = password
      freeze
    end

    # @return [String] a fixed redacted marker; never the password
    def inspect
      REDACTED
    end
    alias to_s inspect

    # `pp` walks an object's instance variables unless `pretty_print` is
    # defined, which would print the password. This keeps it redacted.
    #
    # @param pp [PP]
    # @return [void]
    def pretty_print(pp)
      pp.text(REDACTED)
    end

    # Deliberate deviation from "to_h is every attribute" (see
    # lib/domain/CLAUDE.md): the password is masked so a serialised hash cannot
    # leak it. Equality therefore compares the readers directly, not `to_h`.
    #
    # @return [Hash]
    def to_h
      { username: username, password: '[REDACTED]' }
    end

    def ==(other)
      other.is_a?(self.class) && other.username == username && other.password == password
    end
    alias eql? ==

    def hash
      [username, password].hash
    end
  end
end
