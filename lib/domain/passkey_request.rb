# frozen_string_literal: true

require 'json'

module Domain
  # What a page asked `navigator.credentials` for, as the injected shim
  # reports it: one JSON message carrying the request id, the operation and
  # the `publicKey` options with every byte field already base64url-encoded.
  #
  # This is the wire format between the page and the browser, so parsing it
  # is Domain (see "the wire format is Domain" in lib/domain/CLAUDE.md). A
  # message that cannot be understood raises `Malformed`; the manager turns
  # that into a `TypeError` for the page.
  #
  # Deliberately absent: an origin. The page could claim any origin it liked,
  # so the Framework supplies the real one from the WebView.
  class PasskeyRequest
    class Malformed < ArgumentError; end

    CREATE = :create
    GET = :get
    OPERATIONS = { 'create' => CREATE, 'get' => GET }.freeze

    ES256 = -7
    PUBLIC_KEY_TYPE = 'public-key'
    DEFAULT_USER_VERIFICATION = 'preferred'
    DEFAULT_MEDIATION = 'optional'
    CONDITIONAL_MEDIATION = 'conditional'

    attr_reader :request_id, :operation, :challenge, :rp_id, :rp_name,
                :user_id, :user_name, :user_display_name, :algorithms,
                :exclude_credential_ids, :allow_credential_ids,
                :user_verification, :mediation

    # Parses the shim's message
    #
    # @param json [String] The message the page posted
    # @return [PasskeyRequest]
    # @raise [Malformed] If the message is not a request this browser can act on
    def self.parse(json)
      data = parse_object(json)
      operation = OPERATIONS[data['op']] or raise Malformed, "unknown operation #{data['op'].inspect}"
      options = data['options']
      raise Malformed, 'options are required' unless options.is_a?(Hash)

      user = hash_or_empty(options['user'])
      if operation == CREATE
        raise Malformed, 'a creation request must name the user' unless present?(user['id']) && present?(user['name'])
      end

      new(
        request_id: required_string(data['id'], 'request id'),
        operation: operation,
        challenge: required_string(options['challenge'], 'challenge'),
        rp_id: operation == CREATE ? hash_or_empty(options['rp'])['id'] : options['rpId'],
        rp_name: hash_or_empty(options['rp'])['name'],
        user_id: user['id'],
        user_name: user['name'],
        user_display_name: user['displayName'],
        algorithms: algorithms_in(options['pubKeyCredParams']),
        exclude_credential_ids: credential_ids_in(options['excludeCredentials']),
        allow_credential_ids: credential_ids_in(options['allowCredentials']),
        user_verification: user_verification_in(operation, options),
        mediation: data['mediation'] || DEFAULT_MEDIATION
      )
    end

    def initialize(request_id:, operation:, challenge:, rp_id: nil, rp_name: nil,
                   user_id: nil, user_name: nil, user_display_name: nil,
                   algorithms: [], exclude_credential_ids: [], allow_credential_ids: [],
                   user_verification: DEFAULT_USER_VERIFICATION, mediation: DEFAULT_MEDIATION)
      @request_id = request_id
      @operation = operation
      @challenge = challenge
      @rp_id = rp_id
      @rp_name = rp_name
      @user_id = user_id
      @user_name = user_name
      @user_display_name = user_display_name
      @algorithms = algorithms.freeze
      @exclude_credential_ids = exclude_credential_ids.freeze
      @allow_credential_ids = allow_credential_ids.freeze
      @user_verification = user_verification
      @mediation = mediation
      freeze
    end

    def create?
      operation == CREATE
    end

    def get?
      operation == GET
    end

    # Whether this browser can produce a key the site will accept. An empty
    # list means the WebAuthn defaults, which include ES256.
    #
    # @return [Boolean]
    def supports_es256?
      algorithms.empty? || algorithms.include?(ES256)
    end

    # A conditional request is the silent autofill probe a login form fires
    # on load; it is not something to interrupt the user for.
    #
    # @return [Boolean]
    def conditional?
      mediation == CONDITIONAL_MEDIATION
    end

    # @return [String, nil] The name to show for the account being registered
    def user_label
      [user_display_name, user_name].find { |value| self.class.present?(value) }
    end

    # @return [Hash] Every attribute, for comparison and inspection
    def to_h
      {
        request_id: request_id, operation: operation, challenge: challenge,
        rp_id: rp_id, rp_name: rp_name, user_id: user_id, user_name: user_name,
        user_display_name: user_display_name, algorithms: algorithms,
        exclude_credential_ids: exclude_credential_ids,
        allow_credential_ids: allow_credential_ids,
        user_verification: user_verification, mediation: mediation
      }
    end

    def ==(other)
      other.is_a?(PasskeyRequest) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    # @param value [Object]
    # @return [Boolean] true for a string with something other than whitespace in it
    def self.present?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def self.parse_object(json)
      data = JSON.parse(json)
      raise Malformed, 'request must be a JSON object' unless data.is_a?(Hash)

      data
    rescue JSON::ParserError, TypeError => e
      raise Malformed, "request is not JSON: #{e.message}"
    end
    private_class_method :parse_object

    def self.required_string(value, name)
      raise Malformed, "#{name} is required" unless present?(value)

      value
    end
    private_class_method :required_string

    def self.hash_or_empty(value)
      value.is_a?(Hash) ? value : {}
    end
    private_class_method :hash_or_empty

    def self.algorithms_in(params)
      Array(params).select { |param| param.is_a?(Hash) && param['type'] == PUBLIC_KEY_TYPE }
                   .map { |param| param['alg'] }
                   .select { |alg| alg.is_a?(Integer) }
    end
    private_class_method :algorithms_in

    def self.credential_ids_in(descriptors)
      Array(descriptors).select { |descriptor| descriptor.is_a?(Hash) }
                        .map { |descriptor| descriptor['id'] }
                        .select { |id| present?(id) }
    end
    private_class_method :credential_ids_in

    def self.user_verification_in(operation, options)
      value = if operation == CREATE
                hash_or_empty(options['authenticatorSelection'])['userVerification']
              else
                options['userVerification']
              end
      present?(value) ? value : DEFAULT_USER_VERIFICATION
    end
    private_class_method :user_verification_in
  end
end
