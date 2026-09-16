# frozen_string_literal: true

require_relative '../adapters/one_password_login_store'
require_relative '../adapters/one_password_cli'
require_relative '../domain/web_origin'
require_relative '../domain/login_form_probe'
require_relative '../domain/login_fill_report'
require_relative '../domain/login_site_match'
require_relative '../domain/login_fill_prompt'
require_relative '../domain/login_fill_notice'

module Managers
  # The login-fill use case, in three steps with the user in between (the shape
  # Managers::PasskeyManager established): `prepare` does every check that
  # needs no user and returns a prompt or a notice; `credential_for` fetches
  # the secret once the user has confirmed an account; `conclude` reads what
  # the page reported.
  #
  # No state is kept between calls -- the prompt carries everything. The
  # password is fetched only in `credential_for`, never in `prepare`, so the
  # secret is read only after the user confirms. Only reason symbols and
  # exception classes are ever logged; never a label, credential or report.
  class LoginFillManager
    # @param store [#list_logins, #password_for]
    def initialize(store: Adapters::OnePasswordLoginStore.new)
      @store = store
    end

    # @param origin [String, nil] the page origin, as the Framework saw it
    # @param probe_json [String] what the probe script reported
    # @return [Domain::LoginFillPrompt, Domain::LoginFillNotice]
    def prepare(origin:, probe_json:)
      return notice(:no_origin) if origin.nil?
      return notice(:insecure_origin) unless Domain::WebOrigin.secure?(origin)

      probe = Domain::LoginFormProbe.parse(probe_json)
      return notice(:no_login_form) unless probe.top? && probe.password_field?

      candidates = list_logins
      return candidates if candidates.is_a?(Domain::LoginFillNotice)

      site_key = Domain::LoginSiteMatch.site_key(Domain::WebOrigin.host(origin))
      matches = Domain::LoginSiteMatch.candidates_for(origin: origin, candidates: candidates)
      return notice(:no_matches, detail: site_key) if matches.empty?

      Domain::LoginFillPrompt.new(origin: origin, site_key: site_key, candidates: matches)
    end

    # @param prompt [Domain::LoginFillPrompt]
    # @param index [Integer] the confirmed candidate's index
    # @param live_origin [String, nil] the origin at confirmation time
    # @return [Domain::LoginCredential, Domain::LoginFillNotice]
    # @raise [ArgumentError] if the index is outside the prompt
    def credential_for(prompt, index, live_origin:)
      return notice(:origin_changed) if live_origin != prompt.origin

      candidate = prompt.candidate_at(index)
      fetch_password(candidate)
    end

    # @param report_json [String] what the fill script reported
    # @return [nil, Domain::LoginFillNotice] nil when filled
    def conclude(report_json)
      report = Domain::LoginFillReport.parse(report_json)
      return nil if report.filled?

      notice(:fill_failed, detail: report.reason.to_s)
    end

    private

    def list_logins
      @store.list_logins
    rescue Adapters::OnePasswordCli::Error, StandardError => e
      store_failure(e)
    end

    def fetch_password(candidate)
      @store.password_for(candidate)
    rescue Adapters::OnePasswordCli::Error, StandardError => e
      store_failure(e)
    end

    # Maps a store failure to a named notice and logs the reason only.
    def store_failure(error)
      reason, detail = reason_for(error)
      warn "Login fill: 1Password #{reason}"
      Domain::LoginFillNotice.new(reason: reason, detail: detail)
    end

    def reason_for(error)
      case error
      when Adapters::OnePasswordCli::NotInstalled then [:not_installed, nil]
      when Adapters::OnePasswordCli::NotSignedIn then [:not_signed_in, nil]
      when Adapters::OnePasswordCli::TimedOut then [:timed_out, nil]
      else [:unavailable, error.message]
      end
    end

    def notice(reason, detail: nil)
      Domain::LoginFillNotice.new(reason: reason, detail: detail)
    end
  end
end
