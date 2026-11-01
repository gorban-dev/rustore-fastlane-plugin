require "fastlane/action"
require_relative "../helper/rustore_auth"
require_relative "../helper/rustore_client"
require_relative "../helper/rustore_logger"
require_relative "../helper/rustore_options"

module Fastlane
  module Actions
    # Dry run for CI: checks that the RuStore API key works and covers the
    # package. Reads the version list only; never creates, deletes or uploads.
    class RustoreCheckAction < Action
      TOTAL_STEPS         = 2
      SHOWN_VERSION_COUNT = 5

      def self.run(params)
        private_key  = RustorePublish::RustoreOptions.private_key!(params)
        package_name = params[:package_name]
        logger       = RustorePublish::RustoreLogger.new(total_steps: TOTAL_STEPS)

        # ── Step 1: Authentication ─────────────────────────────────────────────
        logger.step(1, "Authentication")
        auth = RustorePublish::RustoreAuth.new(
          key_id:      params[:key_id],
          private_key: private_key,
          logger:      logger
        )
        auth.refresh!
        logger.success("JWE token obtained")

        # ── Step 2: Versions ───────────────────────────────────────────────────
        logger.step(2, "Versions")
        client = RustorePublish::RustoreClient.new(auth: auth, logger: logger)

        begin
          versions = client.list_versions(package_name: package_name)
        rescue RustorePublish::RustoreClient::NotFoundError
          logger.success(
            "RuStore OK — авторизация прошла, ключ покрывает #{package_name}; активных версий нет, " \
            "API версий откроется после первой публикации в консоли"
          )
          logger.finalize
          return []
        end

        if versions.empty?
          logger.success("RuStore OK — авторизация прошла, версий у #{package_name} нет")
        else
          latest = versions.sort_by { |v| -v["versionId"].to_i }.first(SHOWN_VERSION_COUNT)
          latest.each { |v| logger.info(format_version(v)) }
          logger.success("RuStore OK — ключ рабочий, версий: #{versions.size}")
        end

        logger.finalize
        versions
      end

      def self.format_version(version)
        %w[versionId versionName versionCode versionStatus]
          .map { |field| "#{field}=#{version[field]}" }
          .join(" ")
      end

      # ── Parameter definitions ────────────────────────────────────────────────

      def self.available_options
        RustorePublish::RustoreOptions.credentials
      end

      def self.description
        "Check that the RuStore API key works for a package, without uploading anything"
      end

      def self.details
        <<~DETAILS
          Gets a token and reads the first page of the app's versions from the
          RuStore Public API, then logs up to 5 latest of them.

          HTTP 404 on the version list counts as success: the key is valid and
          covers the package, but RuStore opens the versions API only after the
          first publication from RuStore Console.

          Does not create, delete or upload anything and does not touch drafts.
        DETAILS
      end

      def self.return_value
        "Array of version hashes as returned by RuStore ([] when the app has no versions)"
      end

      def self.authors
        ["Sergey Gorban"]
      end

      def self.example_code
        [
          'rustore_check(
            package_name: "com.example.app",
            key_id:       ENV["RUSTORE_KEY_ID"],
            private_key:  ENV["RUSTORE_PRIVATE_KEY"]
          )'
        ]
      end

      def self.category
        :production
      end

      def self.is_supported?(platform)
        platform == :android
      end
    end
  end
end