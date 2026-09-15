# frozen_string_literal: true

require 'json'

module Domain
  # The `navigator.credentials` implementation injected into every page.
  #
  # WebKitGTK has no WebAuthn, so the page gets this script before any of its
  # own run. It serialises each `create`/`get` call into one JSON message for
  # the `passkey` message handler, parks the promise under a request id, and
  # settles it when the Framework calls `window.__toyPasskey.complete` with a
  # `Domain::PasskeyResponse`.
  #
  # A constant script rather than a file, following `Domain::MermaidScript`.
  module PasskeyShimJs
    HANDLER_NAME = 'passkey'

    # @return [String] JavaScript, safe to inject at document start
    def self.script
      SCRIPT
    end

    # The statement that settles a page's request
    #
    # @param response [Domain::PasskeyResponse]
    # @return [String] JavaScript
    def self.completion_call(response)
      # script_safe escapes U+2028/U+2029, which JSON allows raw but which end
      # a JavaScript statement.
      "window.__toyPasskey.complete(#{JSON.generate(response.to_h, script_safe: true)});"
    end

    SCRIPT = <<~JS.freeze
      (function () {
        'use strict';
        if (window.__toyPasskey) { return; }

        var HANDLER = '#{HANDLER_NAME}';
        var pending = {};
        var sequence = 0;

        function toBytes(source) {
          if (source instanceof ArrayBuffer) { return new Uint8Array(source); }
          if (ArrayBuffer.isView(source)) { return new Uint8Array(source.buffer, source.byteOffset, source.byteLength); }
          throw new TypeError('Expected a BufferSource');
        }

        function encode(source) {
          var bytes = toBytes(source);
          var binary = '';
          for (var i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
          return btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
        }

        function decode(text) {
          var base64 = String(text).replace(/-/g, '+').replace(/_/g, '/');
          while (base64.length % 4) { base64 += '='; }
          var binary = atob(base64);
          var bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
          return bytes.buffer;
        }

        function encodeDescriptors(list) {
          return (list || []).map(function (descriptor) {
            return { type: descriptor.type, id: encode(descriptor.id), transports: descriptor.transports || [] };
          });
        }

        function decodeDescriptors(list) {
          return (list || []).map(function (descriptor) {
            return { type: descriptor.type, id: decode(descriptor.id), transports: descriptor.transports || [] };
          });
        }

        function serialize(op, publicKey) {
          var out = { challenge: encode(publicKey.challenge) };
          if (op === 'create') {
            out.rp = publicKey.rp;
            out.user = { id: encode(publicKey.user.id), name: publicKey.user.name, displayName: publicKey.user.displayName };
            out.pubKeyCredParams = publicKey.pubKeyCredParams || [];
            out.excludeCredentials = encodeDescriptors(publicKey.excludeCredentials);
            out.authenticatorSelection = publicKey.authenticatorSelection || {};
            out.attestation = publicKey.attestation || 'none';
          } else {
            out.rpId = publicKey.rpId;
            out.allowCredentials = encodeDescriptors(publicKey.allowCredentials);
            out.userVerification = publicKey.userVerification || 'preferred';
          }
          return out;
        }

        function failure(name, message) {
          return name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
        }

        function request(op, options) {
          return new Promise(function (resolve, reject) {
            if (!options || !options.publicKey) {
              reject(failure('NotSupportedError', 'Only public-key credentials are supported'));
              return;
            }
            var id = 'passkey-' + (++sequence);
            var message;
            try {
              message = JSON.stringify({ id: id, op: op, mediation: options.mediation || 'optional', options: serialize(op, options.publicKey) });
            } catch (error) {
              reject(error instanceof TypeError ? error : failure('TypeError', String(error)));
              return;
            }
            pending[id] = { resolve: resolve, reject: reject };
            try {
              window.webkit.messageHandlers[HANDLER].postMessage(message);
            } catch (error) {
              delete pending[id];
              reject(failure('NotAllowedError', 'The passkey bridge is unavailable'));
            }
          });
        }

        function PublicKeyCredential() { throw new TypeError('Illegal constructor'); }
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
        PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(false); };
        PublicKeyCredential.parseCreationOptionsFromJSON = function (json) {
          var options = Object.assign({}, json);
          options.challenge = decode(json.challenge);
          options.user = Object.assign({}, json.user, { id: decode(json.user.id) });
          options.excludeCredentials = decodeDescriptors(json.excludeCredentials);
          return options;
        };
        PublicKeyCredential.parseRequestOptionsFromJSON = function (json) {
          var options = Object.assign({}, json);
          options.challenge = decode(json.challenge);
          options.allowCredentials = decodeDescriptors(json.allowCredentials);
          return options;
        };
        PublicKeyCredential.prototype.getClientExtensionResults = function () { return {}; };

        function build(credential) {
          var isRegistration = !!credential.attestationObject;
          var response;
          if (isRegistration) {
            response = {
              clientDataJSON: decode(credential.clientDataJSON),
              attestationObject: decode(credential.attestationObject),
              getTransports: function () { return credential.transports || []; },
              getAuthenticatorData: function () { return decode(credential.authenticatorData); },
              getPublicKey: function () { return decode(credential.publicKey); },
              getPublicKeyAlgorithm: function () { return credential.publicKeyAlgorithm; }
            };
          } else {
            response = {
              clientDataJSON: decode(credential.clientDataJSON),
              authenticatorData: decode(credential.authenticatorData),
              signature: decode(credential.signature),
              userHandle: credential.userHandle ? decode(credential.userHandle) : null
            };
          }
          var result = Object.create(PublicKeyCredential.prototype);
          Object.defineProperties(result, {
            id: { value: credential.id, enumerable: true },
            rawId: { value: decode(credential.id), enumerable: true },
            type: { value: 'public-key', enumerable: true },
            authenticatorAttachment: { value: 'platform', enumerable: true },
            response: { value: response, enumerable: true }
          });
          result.toJSON = function () {
            var json = {
              id: credential.id, rawId: credential.id, type: 'public-key',
              authenticatorAttachment: 'platform', clientExtensionResults: {}
            };
            if (isRegistration) {
              json.response = {
                clientDataJSON: credential.clientDataJSON, attestationObject: credential.attestationObject,
                authenticatorData: credential.authenticatorData, transports: credential.transports || [],
                publicKey: credential.publicKey, publicKeyAlgorithm: credential.publicKeyAlgorithm
              };
            } else {
              json.response = {
                clientDataJSON: credential.clientDataJSON, authenticatorData: credential.authenticatorData,
                signature: credential.signature, userHandle: credential.userHandle || null
              };
            }
            return json;
          };
          return result;
        }

        window.__toyPasskey = {
          complete: function (result) {
            var entry = pending[result.id];
            if (!entry) { return false; }
            delete pending[result.id];
            if (result.ok) {
              entry.resolve(build(result.credential));
            } else {
              entry.reject(failure(result.error.name, result.error.message));
            }
            return true;
          }
        };

        var container = {
          create: function (options) { return request('create', options); },
          get: function (options) { return request('get', options); },
          preventSilentAccess: function () { return Promise.resolve(); },
          store: function () { return Promise.reject(failure('NotSupportedError', 'Storing credentials is not supported')); }
        };
        Object.defineProperty(navigator, 'credentials', { value: container, configurable: true, enumerable: true });
        window.PublicKeyCredential = PublicKeyCredential;
      })();
    JS
    private_constant :SCRIPT
  end
end
