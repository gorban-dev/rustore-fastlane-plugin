require "faraday"
require "faraday/multipart"
require "json"
require_relative "rustore_auth"
require_relative "rustore_logger"

module Fastlane
  module RuStore
    # HTTP client for the RuStore Public API.
    #
    # All methods raise via RustoreLogger#error on non-2xx responses so that
    # callers never need to inspect raw HTTP status codes.
    #
    # Base URL: https://public-api.rustore.ru/public/v1
    class RustoreClient
      BASE_URL = "https://public-api.rustore.ru/public/v1"

      # Supported values for servicesType query param
      SERVICES_TYPE_UNKNOWN = "Unknown"
      SERVICES_TYPE_HMS     = "HMS"

      # Draft version statuses that indicate moderation is complete
      MODERATION_DONE_STATUSES = %w[
        APPROVED
        DECLINED
        ACTIVE
        PUBLISHED
      ].freeze

      MODERATION_FAILED_STATUSES = %w[DECLINED].freeze

      def initialize(auth:, logger: nil)
        @auth   = auth
        @logger = logger || RustoreLogger.new
        @conn   = build_connection
      end

      # ── Version Draft ───────────────────────────────────────────────────────

      # POST /application/{package}/version
      # Creates a new version draft and returns the versionId (Integer).
      def create_draft(package_name:, **metadata)
        resp = post(
          "application/#{package_name}/version",
          metadata
        )
        body       = resp["body"]
        version_id = if body.is_a?(Hash)
                       body["publishId"] || body["versionId"]
                     else
                       body  # API returns the version ID directly as an integer
                     end

        if version_id.nil?
          @logger.error(
            "RuStore API did not return a versionId after draft creation",
            hint: "Response body: #{resp.inspect.slice(0, 300)}"
          )
        end

        version_id.to_i
      end

      # GET /application/{package}/version
      # Returns the list of versions. Finds the current draft if present.
      def find_existing_draft(package_name:)
        resp = get("application/#{package_name}/version")
        versions = resp.dig("body", "content") || resp["body"] || []
        versions.find { |v| v["versionStatus"] == "DRAFT" }
      end

      # DELETE /application/{package}/version/{versionId}
      def delete_draft(package_name:, version_id:)
        delete("application/#{package_name}/version/#{version_id}")
      end

      # ── File Upload ─────────────────────────────────────────────────────────

      # POST /application/{package}/version/{id}/aab
      # Uploads an AAB file. The AAB is always treated as the main artifact.
      #
      # @param file_path [String] absolute path to the .aab file
      def upload_aab(package_name:, version_id:, file_path:)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/aab",
          file_path:    file_path,
          content_type: "application/octet-stream"
        )
      end

      # POST /application/{package}/version/{id}/apk
      # Uploads an APK file.
      #
      # @param services_type [String] "Unknown" (default/GMS) or "HMS"
      # @param is_main_apk   [Boolean] true if this is the primary APK
      def upload_apk(package_name:, version_id:, file_path:,
                     services_type: SERVICES_TYPE_UNKNOWN, is_main_apk: true)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/apk",
          file_path:    file_path,
          content_type: "application/vnd.android.package-archive",
          query:        { servicesType: services_type, isMainApk: is_main_apk }
        )
      end

      # POST /application/{package}/version/{id}/icon
      # Uploads an app icon (PNG).
      def upload_icon(package_name:, version_id:, file_path:)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/icon",
          file_path:    file_path,
          content_type: "image/png"
        )
      end

      # POST /application/{package}/version/{id}/screenshot?ordinal={n}
      # Uploads a screenshot (PNG/JPG). ordinal is 1-based display order.
      def upload_screenshot(package_name:, version_id:, file_path:, ordinal: 1)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/screenshot",
          file_path:    file_path,
          content_type: "image/png",
          query:        { ordinal: ordinal }
        )
      end

      # ── Submission ──────────────────────────────────────────────────────────

      # POST /application/{package}/version/{id}/commit
      # Submits the draft for moderation.
      def submit_for_review(package_name:, version_id:, priority: 5)
        post(
          "application/#{package_name}/version/#{version_id}/commit",
          { sendToReview: true, priority: priority }
        )
      end

      # ── Status Polling ──────────────────────────────────────────────────────

      # GET /application/{package}/version/{id}
      # Returns status information for a specific version.
      def version_status(package_name:, version_id:)
        resp = get("application/#{package_name}/version/#{version_id}")
        resp.dig("body", "versionStatus") || resp.dig("body", "moderationStatus")
      end

      # Polls version_status until moderation completes or timeout is reached.
      # Raises via logger on failure or timeout.
      #
      # @param poll_interval [Integer] seconds between status checks
      # @param timeout       [Integer] total seconds to wait
      def wait_for_moderation(package_name:, version_id:, timeout: 600, poll_interval: 30)
        deadline = Time.now + timeout
        elapsed  = 0

        loop do
          status = version_status(package_name: package_name, version_id: version_id)
          @logger.info("Moderation status: #{status} (elapsed: #{elapsed}s)")

          if MODERATION_DONE_STATUSES.include?(status)
            if MODERATION_FAILED_STATUSES.include?(status)
              @logger.error(
                "Moderation declined by RuStore (status: #{status})",
                hint: "Check the RuStore Console for reviewer comments"
              )
            end
            return status
          end

          if Time.now >= deadline
            @logger.error(
              "Timed out waiting for moderation after #{timeout}s (last status: #{status})",
              hint: "Increase the `timeout` parameter or check moderation status in RuStore Console"
            )
          end

          sleep(poll_interval)
          elapsed += poll_interval
        end
      end

      # ── Publication ─────────────────────────────────────────────────────────

      # PUT /application/{package}/version/{id}/publish-settings
      # Configures publication type, release date, and rollout percentage.
      #
      # @param publish_type       [String]  "INSTANTLY" | "MANUAL" | "DELAYED"
      # @param release_date       [String]  ISO 8601, required for "DELAYED"
      # @param rollout_percentage [Integer] 1-100, nil means 100%
      def configure_publication(package_name:, version_id:,
                                publish_type: "INSTANTLY",
                                release_date: nil,
                                rollout_percentage: nil)
        body = { publishType: publish_type }
        body[:releaseDateTime]    = release_date       if release_date
        body[:partialPublishValue] = rollout_percentage if rollout_percentage

        put("application/#{package_name}/version/#{version_id}/publish-settings", body)
      end

      # POST /application/{package}/version/{id}/publish
      # Manually triggers publication (only needed for MANUAL publish_type).
      def publish(package_name:, version_id:)
        post("application/#{package_name}/version/#{version_id}/publish", {})
      end

      private

      # ── HTTP Helpers ─────────────────────────────────────────────────────────

      def get(path)
        resp = @conn.get(path) { |r| r.headers["Public-Token"] = @auth.token }
        handle_response(resp, path)
      end

      def post(path, body)
        resp = @conn.post(path) do |r|
          r.headers["Public-Token"]  = @auth.token
          r.headers["Content-Type"]  = "application/json"
          r.body                     = JSON.generate(body)
        end
        handle_response(resp, path)
      end

      def put(path, body)
        resp = @conn.put(path) do |r|
          r.headers["Public-Token"]  = @auth.token
          r.headers["Content-Type"]  = "application/json"
          r.body                     = JSON.generate(body)
        end
        handle_response(resp, path)
      end

      def delete(path)
        resp = @conn.delete(path) { |r| r.headers["Public-Token"] = @auth.token }
        handle_response(resp, path)
      end

      # Multipart file upload with optional query params and progress logging.
      def upload_file(path:, file_path:, content_type:, query: {})
        filename = File.basename(file_path)
        size_mb  = (File.size(file_path) / 1_048_576.0).round(1)

        @logger.info("Uploading #{filename} (#{size_mb} MB)")

        url = query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}"

        resp = @conn.post(url) do |req|
          req.headers["Public-Token"] = @auth.token
          req.body = {
            file: Faraday::UploadIO.new(file_path, content_type, filename)
          }
        end

        handle_response(resp, path)
      end

      def handle_response(resp, path)
        body = safe_parse_json(resp.body)

        unless resp.success?
          api_message = body&.dig("message") || body&.dig("body", "message") || resp.body.to_s.slice(0, 300)
          @logger.error(
            "API request failed [#{resp.status}] #{path}: #{api_message}",
            hint: error_hint(resp.status, api_message)
          )
        end

        # RuStore sometimes returns 200 with code != "OK"
        api_code = body&.dig("code")
        if api_code && api_code != "OK" && api_code != "200"
          api_message = body&.dig("message") || "code=#{api_code}"
          @logger.error(
            "API returned error code '#{api_code}' on #{path}: #{api_message}",
            hint: error_hint(nil, api_message)
          )
        end

        body || {}
      end

      def error_hint(status, message)
        case status
        when 401 then "Token is invalid or expired — check key_id and private_key"
        when 403 then "Key does not have permission for this operation — check RuStore Console API key settings"
        when 404 then "Resource not found — verify package_name and that at least 1 active version exists in RuStore Console"
        when 422 then "Validation error: #{message}"
        when 429 then "Rate limited — wait before retrying"
        else message
        end
      end

      def build_connection
        Faraday.new(url: BASE_URL) do |f|
          f.request  :multipart
          f.request  :url_encoded
          f.response :logger, nil, { headers: false, bodies: false } if ENV["RUSTORE_DEBUG"]
          f.adapter  Faraday.default_adapter
          f.options.timeout      = 300  # 5 min for large file uploads
          f.options.open_timeout = 15
        end
      end

      def safe_parse_json(str)
        JSON.parse(str.to_s)
      rescue StandardError
        {}
      end
    end
  end
end
