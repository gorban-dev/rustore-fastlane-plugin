require "faraday"
require "faraday/multipart"
require "json"
require_relative "rustore_auth"
require_relative "rustore_logger"
require_relative "rustore_endpoint"

module Fastlane
  module RustorePublish
    # HTTP client for the RuStore Public API.
    #
    # All methods raise via RustoreLogger#error on non-2xx responses and on
    # network failures, so that callers never need to inspect raw HTTP status
    # codes or Faraday exceptions.
    #
    # Base URL: https://public-api-m.rustore.ru/public/v1 (see RustoreEndpoint)
    class RustoreClient
      # RuStore answers a file upload only after it has checked the file
      # (permissions, SDKs), which can take minutes
      DEFAULT_UPLOAD_TIMEOUT = 900
      REQUEST_TIMEOUT        = 300
      WAIT_LOG_INTERVAL      = 60

      # Supported values for servicesType query param
      SERVICES_TYPE_UNKNOWN = "Unknown"
      SERVICES_TYPE_HMS     = "HMS"

      def initialize(auth:, logger: nil, upload_timeout: DEFAULT_UPLOAD_TIMEOUT, wait_log_interval: WAIT_LOG_INTERVAL)
        @auth              = auth
        @logger            = logger || RustoreLogger.new
        @upload_timeout    = upload_timeout
        @wait_log_interval = wait_log_interval
        @conn              = build_connection
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

      # GET /application/{package}/version?versionStatuses=DRAFT
      # Returns the current draft if present.
      def find_existing_draft(package_name:)
        resp = get("application/#{package_name}/version?versionStatuses=DRAFT")
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
      # @return [Hash] parsed response (body has permissions and autoDetectedSdks)
      def upload_aab(package_name:, version_id:, file_path:)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/aab",
          version_id:   version_id,
          file_path:    file_path,
          content_type: "application/octet-stream"
        )
      end

      # POST /application/{package}/version/{id}/apk
      # Uploads an APK file.
      #
      # @param services_type [String] "Unknown" (default/GMS) or "HMS"
      # @param is_main_apk   [Boolean] true if this is the primary APK
      # @return [Hash] parsed response (body has permissions and autoDetectedSdks)
      def upload_apk(package_name:, version_id:, file_path:,
                     services_type: SERVICES_TYPE_UNKNOWN, is_main_apk: true)
        upload_file(
          path:         "application/#{package_name}/version/#{version_id}/apk",
          version_id:   version_id,
          file_path:    file_path,
          content_type: "application/vnd.android.package-archive",
          query:        { servicesType: services_type, isMainApk: is_main_apk }
        )
      end

      # ── Submission ──────────────────────────────────────────────────────────

      # POST /application/{package}/version/{id}/commit?priorityUpdate={n}
      # Submits the draft for moderation.
      #
      # @param update_priority [Integer] in-app update priority, 0 (min) to 5 (max)
      def submit_for_review(package_name:, version_id:, update_priority: 0)
        post(
          "application/#{package_name}/version/#{version_id}/commit?priorityUpdate=#{update_priority}",
          {}
        )
      end

      private

      # ── HTTP Helpers ─────────────────────────────────────────────────────────

      def get(path)
        resp = with_network_errors(path) do
          @conn.get(path) { |r| r.headers["Public-Token"] = @auth.token }
        end
        handle_response(resp, path)
      end

      def post(path, body)
        resp = with_network_errors(path) do
          @conn.post(path) do |r|
            r.headers["Public-Token"]  = @auth.token
            r.headers["Content-Type"]  = "application/json"
            r.body                     = JSON.generate(body)
          end
        end
        handle_response(resp, path)
      end

      def delete(path)
        resp = with_network_errors(path) do
          @conn.delete(path) { |r| r.headers["Public-Token"] = @auth.token }
        end
        handle_response(resp, path)
      end

      # Multipart file upload. Logs when the file has been sent, a heartbeat
      # while RuStore is processing it, and the response time.
      def upload_file(path:, version_id:, file_path:, content_type:, query: {})
        filename = File.basename(file_path)
        size_mb  = (File.size(file_path) / 1_048_576.0).round(1)
        url      = query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}"

        @logger.info("Sending #{filename} (#{size_mb} MB)")
        started_at  = monotonic_now
        tracked_io  = SendTrackingIO.new(file_path) do |finished_at|
          @logger.info("#{filename} sent in #{(finished_at - started_at).round(1)}s, waiting for RuStore to check it")
        end
        upload      = { filename: filename, version_id: version_id }
        heartbeat   = start_heartbeat(tracked_io, filename)

        resp = with_network_errors(path, upload: upload) do
          @conn.post(url) do |req|
            req.options.timeout = @upload_timeout
            req.headers["Public-Token"] = @auth.token
            req.body = {
              file: Faraday::UploadIO.new(tracked_io, content_type, filename)
            }
          end
        end

        sent_at = tracked_io.finished_at || started_at
        @logger.info("RuStore responded in #{(monotonic_now - sent_at).round}s")

        result = handle_response(resp, path)
        log_detected_items(result["body"])
        result
      ensure
        heartbeat&.kill&.join
        tracked_io&.close
      end

      # Logs every @wait_log_interval seconds until the response arrives,
      # so a long wait does not look like a hung job.
      def start_heartbeat(tracked_io, filename)
        Thread.new do
          loop do
            sleep(@wait_log_interval)
            finished_at = tracked_io.finished_at
            if finished_at.nil?
              @logger.info("Still sending #{filename}: #{(tracked_io.bytes / 1_048_576.0).round(1)} MB so far")
              next
            end
            @logger.info("Waiting for RuStore response: #{(monotonic_now - finished_at).round}s / #{@upload_timeout}s")
          end
        end
      end

      # RuStore returns the permissions and SDKs it found in the uploaded file.
      def log_detected_items(body)
        return unless body.is_a?(Hash)

        permissions = (body["permissions"] || {}).flat_map do |_category, items|
          Array(items).map { |item| item.is_a?(Hash) ? item["permission"] : item }
        end.compact
        @logger.info("Permissions detected by RuStore: #{permissions.join(', ')}") unless permissions.empty?

        sdks = (body["autoDetectedSdks"] || {}).reject { |_category, names| Array(names).empty? }
        unless sdks.empty?
          @logger.info("SDKs detected by RuStore: " + sdks.map { |category, names| "#{category}: #{Array(names).join(', ')}" }.join("; "))
        end
      end

      # Turns Faraday network exceptions into a logged error with a hint.
      # SSLError is rescued first: in Faraday it is not a ConnectionFailed.
      def with_network_errors(path, upload: nil)
        yield
      rescue Faraday::SSLError => e
        @logger.error(
          "TLS handshake with #{RustoreEndpoint::HOST} failed: #{e.message}",
          hint: "The plugin trusts the system roots plus the bundled Russian Trusted Root CA. " \
                "Check that no proxy replaces the certificate and that the system CA store is readable (SSL_CERT_FILE)"
        )
      rescue Faraday::TimeoutError => e
        if upload
          @logger.error(
            "RuStore did not respond to the upload of #{upload[:filename]} within #{@upload_timeout}s " \
            "(versionId=#{upload[:version_id]}): #{e.message}",
            hint: "The draft stays in RuStore and is replaced on the next run, so rerunning the lane is safe. " \
                  "If RuStore is just slow, raise `upload_timeout` (RUSTORE_UPLOAD_TIMEOUT)"
          )
        else
          @logger.error(
            "RuStore did not respond to #{path} within #{REQUEST_TIMEOUT}s: #{e.message}",
            hint: "Rerunning the lane is safe: an unfinished draft is replaced on the next run"
          )
        end
      rescue Faraday::ConnectionFailed => e
        @logger.error(
          "Could not connect to #{RustoreEndpoint::HOST}: #{e.message}",
          hint: "Check DNS, proxy and firewall from this machine to #{RustoreEndpoint::HOST}:443"
        )
      end

      def handle_response(resp, path, raise_error: true)
        body = safe_parse_json(resp.body)

        unless resp.success?
          api_message = body&.dig("message") || body&.dig("body", "message")
          if api_message.nil? && resp.status >= 500
            api_message = "RuStore returned a non-JSON response (#{resp.body.to_s.bytesize} bytes)"
          end
          api_message ||= resp.body.to_s.slice(0, 300)
          api_message = "(empty response body)" if api_message.to_s.strip.empty?

          if raise_error
            @logger.error(
              "API request failed [#{resp.status}] #{path}: #{api_message}",
              hint: error_hint(resp.status, api_message)
            )
          else
            @logger.warning("API request failed [#{resp.status}] #{path}: #{api_message}")
            return nil
          end
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
        text = message.to_s
        return "Upload the file in RuStore Console, fill in the permission declaration and submit the draft from there" if text.include?("new sensitive permissions")
        return "Remove the listed permissions from the build and upload it again" if text.include?("illegal permissions")

        case status
        when 401 then "Token is invalid or expired — check key_id and private_key"
        when 403 then "Key does not have permission for this operation — check RuStore Console API key settings"
        when 404 then "Resource not found — verify package_name and that at least 1 active version exists in RuStore Console"
        when 422 then "Validation error: #{message}"
        when 429 then "Rate limited — wait before retrying"
        when 500..599 then "Failure on the RuStore side; the draft is not submitted, rerunning the lane is safe"
        else message
        end
      end

      def build_connection
        Faraday.new(url: RustoreEndpoint::BASE_URL, ssl: { cert_store: RustoreEndpoint.cert_store }) do |f|
          f.request  :multipart
          f.request  :url_encoded
          f.response :logger, nil, { headers: false, bodies: false } if ENV["RUSTORE_DEBUG"]
          f.adapter  Faraday.default_adapter
          f.options.timeout      = REQUEST_TIMEOUT
          f.options.open_timeout = 15
        end
      end

      def safe_parse_json(str)
        JSON.parse(str.to_s)
      rescue StandardError
        {}
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Wraps a file IO and records when the last byte has been read, i.e. the
      # moment the file has been handed to the socket, and calls the block once
      # at that moment. Fully compatible with Faraday::UploadIO (responds to
      # read, size, eof?, rewind, close, path).
      class SendTrackingIO
        attr_reader :bytes, :finished_at

        def initialize(file_path, &on_finish)
          @io          = File.open(file_path, "rb")
          @total       = File.size(file_path)
          @bytes       = 0
          @finished_at = nil
          @on_finish   = on_finish
        end

        def read(length = nil, outbuf = nil)
          chunk = length ? @io.read(length) : @io.read
          @bytes += chunk.bytesize if chunk
          if @finished_at.nil? && @bytes >= @total
            @finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @on_finish&.call(@finished_at)
          end
          outbuf ? (outbuf.replace(chunk || ""); outbuf) : chunk
        end

        def size;   @total;                                end
        def eof?;   @io.eof?;                              end
        def rewind; @io.rewind; @bytes = 0; @finished_at = nil; end
        def close;  @io.close unless @io.closed?;          end
        def path;   @io.path;                              end
      end
    end
  end
end
