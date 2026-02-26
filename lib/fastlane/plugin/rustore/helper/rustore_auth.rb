require "openssl"
require "base64"
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
    #   2. Build request body: { keyId, timestamp, signature }
    #      where signature = Base64( RSA-SHA512( keyId + timestamp ) )
    #   3. POST to /public/auth → receive a JWE token (TTL 900s).
    #   4. Cache the token; auto-refresh when it's within REFRESH_BEFORE
    #      seconds of expiry.
    #
    # Reference: https://www.rustore.ru/help/en/work-with-rustore-api/api-authorization-token
    class RustoreAuth
      AUTH_URL       = "https://public-api.rustore.ru/public/auth"
      TOKEN_TTL      = 900  # seconds (as documented by RuStore)
      REFRESH_BEFORE = 60   # refresh the token this many seconds before expiry

      def initialize(key_id:, private_key:, logger: nil)
        @key_id     = key_id
        @logger     = logger || RustoreLogger.new
        @rsa_key    = load_rsa_key(private_key)
        @token      = nil
        @expires_at = nil
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

      # Builds the auth request body:
      #   keyId     — API key identifier from RuStore Console
      #   timestamp — ISO 8601 with milliseconds and timezone offset
      #   signature — Base64-encoded RSA-SHA512 signature of (keyId + timestamp)
      def build_auth_body
        timestamp = build_timestamp
        message   = "#{@key_id}#{timestamp}"
        digest    = OpenSSL::Digest::SHA512.new
        signature = Base64.strict_encode64(@rsa_key.sign(digest, message))

        { keyId: @key_id, timestamp: timestamp, signature: signature }
      end

      # Formats the current time as ISO 8601 with milliseconds and UTC offset.
      # Example: "2024-01-01T10:00:00.000+03:00"
      def build_timestamp
        t = Time.now
        t.strftime("%Y-%m-%dT%H:%M:%S.%3N") + t.strftime("%:z")
      end

      # POST auth body to RuStore and return the JWE token string.
      def fetch_jwe_token
        uri = URI(AUTH_URL)

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(build_auth_body)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.read_timeout = 30
          http.open_timeout = 10
          http.request(request)
        end

        handle_auth_response(response)
      end

      def handle_auth_response(response)
        unless response.is_a?(Net::HTTPSuccess)
          body    = safe_parse_json(response.body)
          message = body&.dig("message") || response.body.to_s.slice(0, 300)
          @logger.error(
            "Authentication failed: #{message}",
            hint: "Verify key_id and private_key are correct and the key has API access enabled in RuStore Console",
            raise_error: true
          )
        end

        body = safe_parse_json(response.body)
        jwe  = body&.dig("body", "jwe") || body&.dig("jwe")

        if jwe.nil? || jwe.empty?
          @logger.error(
            "Authentication response did not contain a JWE token",
            hint: "Unexpected API response format: #{response.body.to_s.slice(0, 200)}",
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

        if pem.strip.start_with?("-----")
          OpenSSL::PKey::RSA.new(pem)
        else
          # Raw base64 without PEM headers (e.g. CI secret stored without BEGIN/END lines).
          # Try PKCS#8 first (RuStore keys), then fall back to traditional PKCS#1.
          load_bare_base64(pem.strip.gsub(/\s+/, ""))
        end
      rescue OpenSSL::PKey::RSAError => e
        @logger.error(
          "Failed to load RSA private key: #{e.message}",
          hint: "Ensure the key is a valid RSA PEM — either a full PEM string " \
                "(with -----BEGIN PRIVATE KEY----- header) or raw base64 content",
          raise_error: true
        )
      end

      # Tries to load a bare base64 DER blob by wrapping it in PEM headers.
      # Attempts PKCS#8 first (RuStore generates PKCS#8 keys), then PKCS#1.
      def load_bare_base64(b64)
        body = b64.scan(/.{1,64}/).join("\n")

        begin
          OpenSSL::PKey::RSA.new("-----BEGIN PRIVATE KEY-----\n#{body}\n-----END PRIVATE KEY-----\n")
        rescue OpenSSL::PKey::RSAError
          OpenSSL::PKey::RSA.new("-----BEGIN RSA PRIVATE KEY-----\n#{body}\n-----END RSA PRIVATE KEY-----\n")
        end
      end

      def safe_parse_json(str)
        JSON.parse(str.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
