# frozen_string_literal: true

require 'json'

module Domain
  # The JavaScript the browser evaluates in the page to probe for a login form
  # and to fill it. Constant strings behind methods, following
  # Domain::PasskeyShimJs and Domain::MermaidScript.
  #
  # Both scripts run in the isolated world WORLD_NAME: the same DOM as the
  # page, but separate JavaScript globals, so the page cannot observe the
  # functions and `JSON` / `Event` / `HTMLInputElement.prototype` are the
  # pristine ones rather than anything the page redefined.
  #
  # The scripts never submit: they set values and dispatch `input`/`change`
  # (which is what React, Vue and Angular listen to) and nothing else. No
  # `submit`, `requestSubmit`, `click` or synthetic key events appear in the
  # text, and a test asserts that.
  module LoginFormJs
    WORLD_NAME = 'toy-browser-login-fill'

    # @return [String] the probe script (an IIFE returning a JSON string)
    def self.probe_script
      PROBE
    end

    # The fill script with its argument appended. The returned string contains
    # the secret, so a caller holds it only long enough to hand to
    # `evaluate_javascript`.
    #
    # @param credential [Domain::LoginCredential]
    # @param origin [String] the origin the fill was confirmed for
    # @return [String]
    def self.fill_call(credential, origin:)
      argument = JSON.generate(
        { username: credential.username, password: credential.password, origin: origin },
        script_safe: true
      )
      "#{FILL}(#{argument});"
    end

    # Shared field heuristics, interpolated into both PROBE and FILL so the two
    # agree on which fields they are talking about: the first visible
    # `input[type=password]`, and the visible text/email/tel/untyped input
    # before it in DOM order within the same form (or the document), preferring
    # `autocomplete=username|email`, then `type=email`, then a name/id/
    # placeholder/aria-label hint, then the nearest one.
    FIELD_FINDER = <<~'JS'
      function visible(el) {
        if (el.disabled || el.readOnly) { return false; }
        if ((el.getAttribute('type') || '').toLowerCase() === 'hidden') { return false; }
        if (el.getClientRects().length === 0) { return false; }
        var style = window.getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      }
      function passwordField() {
        var inputs = document.querySelectorAll('input[type="password"]');
        for (var i = 0; i < inputs.length; i++) { if (visible(inputs[i])) { return inputs[i]; } }
        return null;
      }
      var USERNAME_TYPES = ['text', 'email', 'tel', ''];
      var USERNAME_HINT = /user|e-?mail|login|account|identifier|phone/i;
      function hint(el) {
        return [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.getAttribute('autocomplete')].join(' ');
      }
      function usernameField(password) {
        var scope = password.form || document;
        var all = Array.prototype.slice.call(scope.querySelectorAll('input'));
        var before = all.slice(0, all.indexOf(password)).filter(function (el) {
          return visible(el) && USERNAME_TYPES.indexOf((el.getAttribute('type') || '').toLowerCase()) !== -1;
        });
        if (before.length === 0) { return null; }
        var byAutocomplete = before.filter(function (el) { return /^(username|email)$/i.test(el.getAttribute('autocomplete') || ''); });
        if (byAutocomplete.length) { return byAutocomplete[byAutocomplete.length - 1]; }
        var byType = before.filter(function (el) { return (el.getAttribute('type') || '').toLowerCase() === 'email'; });
        if (byType.length) { return byType[byType.length - 1]; }
        var byHint = before.filter(function (el) { return USERNAME_HINT.test(hint(el)); });
        if (byHint.length) { return byHint[byHint.length - 1]; }
        return before[before.length - 1];
      }
    JS

    PROBE = <<~JS.freeze
      (function () {
        'use strict';
        #{FIELD_FINDER}
        var report = { top: window.top === window, origin: window.location.origin, password: false, username: false };
        var password = passwordField();
        if (password) { report.password = true; report.username = !!usernameField(password); }
        return JSON.stringify(report);
      })();
    JS

    FILL = <<~JS.freeze
      (function (fill) {
        'use strict';
        #{FIELD_FINDER}
        function setValue(el, value) {
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          el.focus();
          setter.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.blur();
        }
        if (window.top !== window) { return JSON.stringify({ ok: false, reason: 'not_top_document' }); }
        if (window.location.origin !== fill.origin) { return JSON.stringify({ ok: false, reason: 'origin_changed' }); }
        var password = passwordField();
        if (!password) { return JSON.stringify({ ok: false, reason: 'no_password_field' }); }
        var username = usernameField(password);
        var fillUsername = !!(username && fill.username !== null);
        if (fillUsername) { setValue(username, fill.username); }
        setValue(password, fill.password);
        return JSON.stringify({ ok: true, username: fillUsername, password: true });
      })
    JS
  end
end
