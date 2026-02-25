require "jwt"
require "openssl"
require "net/http"
require "json"
require "uri"
require_relative "rustore_logger"

module Fastlane
  module RuStore
    # Handles authentication against the RuStore Public API.
    #
    # Flow:
    #   1. Load RSA private key (PEM file or inline string).
    #   2. Build a signed JWT (RS256) with key_id in the header.
    #   3. POST the JWT to /public/auth/ → receive a JWE token.
    #   4. Cache the token; auto-refresh when it's within REFRESH_BEFORE
    #      seconds of expiry.
    #
    # Reference: https://www.rustore.ru/help/en/work-with-rustore-api/api-authorization-process
    class RustoreAuth
      AUTH_URL       = "https://public-api.rustore.ru/public/auth"
      TOKEN_TTL      = 900  # seconds (as documented by RuStore)
      REFRESH_BEFORE = 60   # refresh the token this many seconds before expiry

      def initialize(key_id:, private_key:, logger: nil)
        @key_id      = key_id
        @logger      = logger || RustoreLogger.new
        @rsa_key     = load_rsa_key(private_key)
        @token       = nil
        @expires_at  = nil
      end

      # Returns a valid JWE token, refreshing if necessary.
      def token
        refresh! if token_expired?
        @token
      end

      # Force-fetches a fresh token regardless of cache state.
      def refresh!
        @logger.verbose("Requesting new JWE token from RuStore auth endpoint")
        jwe = fetch_jwe_token
        @token      = jwe
        @expires_at = Time.now + TOKEN_TTL - REFRESH_BEFORE
        @logger.verbose("Token cached, valid for #{TOKEN_TTL}s (refresh in #{TOKEN_TTL - REFRESH_BEFORE}s)")
        @token
      end

      private

      def token_expired?
        @token.nil? || @expires_at.nil? || Time.now >= @expires_at
      end

      # Build a minimal JWT signed with the RSA private key.
      # RuStore uses the `kid` (key ID) header claim to identify the key.
      def build_jwt
        payload = {
          iss: @key_id,   # issuer = key_id as documented
          iat: Time.now.to_i
        }
        headers = { kid: @key_id }
        JWT.encode(payload, @rsa_key, "RS256", headers)
      end

      # POST the signed JWT to RuStore auth and return the JWE token string.
      def fetch_jwe_token
        jwt = build_jwt
        uri = URI(AUTH_URL)

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ jwe: jwt })

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.read_timeout = 30
          http.open_timeout = 10
          http.request(request)
        end

        handle_auth_response(response)
      end

      def handle_auth_response(response)
        unless response.is_a?(Net::HTTPSuccess)
          body = safe_parse_json(response.body)
          message = body&.dig("message") || response.body || "HTTP #{response.code}"
          @logger.error(
            "Authentication failed: #{message}",
            hint: "Verify key_id and private_key are correct and the key has API access enabled in RuStore Console",
            raise_error: true
          )
        end

        body = safe_parse_json(response.body)

        # RuStore wraps responses in { "body": { "jwe": "..." }, "code": "OK" }
        jwe = body&.dig("body", "jwe") || body&.dig("jwe")

        if jwe.nil? || jwe.empty?
          @logger.error(
            "Authentication response did not contain a JWE token",
            hint: "Unexpected API response format: #{response.body.slice(0, 200)}",
            raise_error: true
          )
        end

        jwe
      end

      def load_rsa_key(private_key)
        pem = if File.exist?(private_key.to_s)
                File.read(private_key)
              else
                private_key
              end
        OpenSSL::PKey::RSA.new(pem)
      rescue OpenSSL::PKey::RSAError => e
        @logger.error(
          "Failed to load RSA private key: #{e.message}",
          hint: "Ensure the key is a valid RSA PEM (PKCS#8 or traditional format)",
          raise_error: true
        )
      end

      def safe_parse_json(str)
        JSON.parse(str)
      rescue StandardError
        nil
      end
    end
  end
end
