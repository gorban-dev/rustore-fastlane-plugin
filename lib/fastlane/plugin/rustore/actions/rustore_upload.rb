require "fastlane/action"
require_relative "../helper/rustore_auth"
require_relative "../helper/rustore_client"
require_relative "../helper/rustore_logger"

module Fastlane
  module Actions
    class RustoreUploadAction < Action
      TOTAL_STEPS = 6

      def self.run(params)
        logger = RuStore::RustoreLogger.new(total_steps: TOTAL_STEPS)

        # ── Step 1: Authentication ─────────────────────────────────────────────
        logger.step(1, "Authentication")

        private_key = params[:private_key] || File.read(params[:private_key_path])
        auth = RuStore::RustoreAuth.new(
          key_id:      params[:key_id],
          private_key: private_key,
          logger:      logger
        )
        auth.refresh!
        logger.success("JWE token obtained (valid 900s, auto-refresh enabled)")

        client       = RuStore::RustoreClient.new(auth: auth, logger: logger)
        package_name = params[:package_name]

        # ── Step 2: Draft Management ───────────────────────────────────────────
        logger.step(2, "Draft Management")

        existing = client.find_existing_draft(package_name: package_name)
        if existing
          draft_id = existing["publishId"] || existing["versionId"]
          logger.warning("Found existing draft (id=#{draft_id}) — deleting it")
          client.delete_draft(package_name: package_name, version_id: draft_id)
          logger.info("Existing draft deleted")
        end

        whats_new  = params[:whats_new]
        moder_info = params[:moder_info]
        draft_meta = {}
        draft_meta[:whatsNew]  = whats_new  if whats_new
        draft_meta[:moderInfo] = moder_info if moder_info

        version_id = client.create_draft(package_name: package_name, **draft_meta)
        logger.success("Draft created (versionId=#{version_id})")
        logger.table([
          ["Package",        package_name],
          ["Version ID",     version_id],
          ["What's new",     whats_new  || "(not set)"],
          ["Moderator note", moder_info || "(not set)"]
        ])

        # ── Step 3: Upload primary build ───────────────────────────────────────
        aab_path     = params[:aab_path]
        apk_path     = params[:apk_path]
        hms_apk_path = params[:hms_apk_path]

        primary_label = aab_path ? "Uploading AAB (GMS/main)" : "Uploading APK (main)"
        logger.step(3, primary_label)

        if aab_path
          validate_file!(aab_path, "aab_path", ".aab", logger)
          logger.table([
            ["File",          File.basename(aab_path)],
            ["Size",          "#{(File.size(aab_path) / 1_048_576.0).round(1)} MB"],
            ["Type",          "AAB (main/GMS)"],
            ["services_type", "Unknown"],
            ["is_main",       "true (implicit for AAB)"]
          ])
          client.upload_aab(
            package_name: package_name,
            version_id:   version_id,
            file_path:    aab_path
          )
          logger.success("AAB uploaded successfully")

        elsif apk_path
          validate_file!(apk_path, "apk_path", ".apk", logger)
          logger.table([
            ["File",          File.basename(apk_path)],
            ["Size",          "#{(File.size(apk_path) / 1_048_576.0).round(1)} MB"],
            ["Type",          "APK (main/GMS)"],
            ["services_type", "Unknown"],
            ["is_main",       "true"]
          ])
          client.upload_apk(
            package_name:  package_name,
            version_id:    version_id,
            file_path:     apk_path,
            services_type: RuStore::RustoreClient::SERVICES_TYPE_UNKNOWN,
            is_main_apk:   true
          )
          logger.success("APK uploaded successfully")
        else
          logger.error(
            "No build file provided",
            hint: "Specify at least `aab_path` or `apk_path`"
          )
        end

        # ── Step 4: Upload HMS APK (optional) ─────────────────────────────────
        logger.step(4, "Uploading APK (HMS/secondary)")

        if hms_apk_path
          validate_file!(hms_apk_path, "hms_apk_path", ".apk", logger)
          logger.table([
            ["File",          File.basename(hms_apk_path)],
            ["Size",          "#{(File.size(hms_apk_path) / 1_048_576.0).round(1)} MB"],
            ["Type",          "APK (secondary/HMS)"],
            ["services_type", "HMS"],
            ["is_main",       "false"]
          ])
          client.upload_apk(
            package_name:  package_name,
            version_id:    version_id,
            file_path:     hms_apk_path,
            services_type: RuStore::RustoreClient::SERVICES_TYPE_HMS,
            is_main_apk:   false
          )
          logger.success("HMS APK uploaded successfully")
        else
          logger.info("Skipped (no hms_apk_path provided)")
        end

        # ── Step 5: Configure publication ─────────────────────────────────────
        logger.step(5, "Configuring publication")

        publish_type       = params[:publish_type]
        release_date       = params[:release_date]
        rollout_percentage = params[:rollout_percentage]

        logger.table([
          ["Publish type",       publish_type],
          ["Release date",       release_date       || "(not set)"],
          ["Rollout percentage", rollout_percentage || "100%"]
        ])

        if release_date && publish_type != "DELAYED"
          logger.warning("release_date is set but publish_type is '#{publish_type}' — only used with DELAYED")
        end

        client.configure_publication(
          package_name:       package_name,
          version_id:         version_id,
          publish_type:       publish_type,
          release_date:       release_date,
          rollout_percentage: rollout_percentage
        )
        logger.success("Publication settings saved")

        # ── Step 6: Submit for moderation ─────────────────────────────────────
        logger.step(6, "Submitting for moderation")
        client.submit_for_review(package_name: package_name, version_id: version_id)

        case publish_type
        when "INSTANTLY"
          logger.success("Submitted — RuStore will publish automatically after moderation")
        when "DELAYED"
          logger.success("Submitted — scheduled for #{release_date}")
        when "MANUAL"
          logger.success("Submitted — publish manually from RuStore Console after moderation passes")
        end

        logger.finalize
        UI.success("#{RuStore::RustoreLogger::PREFIX} All done! #{package_name} versionId=#{version_id} submitted to RuStore.")
      end

      # ── Parameter definitions ────────────────────────────────────────────────

      def self.available_options
        [
          # ── Authentication ─────────────────────────────────────────────────
          FastlaneCore::ConfigItem.new(
            key:         :key_id,
            env_name:    "RUSTORE_KEY_ID",
            description: "API key ID from RuStore Console → Company → API RuStore",
            type:        String,
            optional:    false
          ),
          FastlaneCore::ConfigItem.new(
            key:         :private_key_path,
            env_name:    "RUSTORE_PRIVATE_KEY_PATH",
            description: "Path to RSA private key PEM file (mutually exclusive with private_key)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("private_key_path file not found: #{v}") unless File.exist?(v) }
          ),
          FastlaneCore::ConfigItem.new(
            key:         :private_key,
            env_name:    "RUSTORE_PRIVATE_KEY",
            description: "RSA private key PEM content (mutually exclusive with private_key_path)",
            type:        String,
            optional:    true,
            sensitive:   true
          ),

          # ── App identity ───────────────────────────────────────────────────
          FastlaneCore::ConfigItem.new(
            key:         :package_name,
            env_name:    "RUSTORE_PACKAGE_NAME",
            description: "Application package name (e.g. com.example.app)",
            type:        String,
            optional:    false
          ),

          # ── Build files ────────────────────────────────────────────────────
          FastlaneCore::ConfigItem.new(
            key:         :aab_path,
            env_name:    "RUSTORE_AAB_PATH",
            description: "Path to AAB file (Google/GMS build — becomes the main artifact)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("aab_path file not found: #{v}") unless File.exist?(v) }
          ),
          FastlaneCore::ConfigItem.new(
            key:         :apk_path,
            env_name:    "RUSTORE_APK_PATH",
            description: "Path to APK file (used when aab_path is not provided; becomes main artifact)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("apk_path file not found: #{v}") unless File.exist?(v) }
          ),
          FastlaneCore::ConfigItem.new(
            key:         :hms_apk_path,
            env_name:    "RUSTORE_HMS_APK_PATH",
            description: "Path to Huawei/HMS APK file (uploaded with servicesType=HMS, isMainApk=false)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("hms_apk_path file not found: #{v}") unless File.exist?(v) }
          ),

          # ── Release notes ──────────────────────────────────────────────────
          FastlaneCore::ConfigItem.new(
            key:         :whats_new,
            env_name:    "RUSTORE_WHATS_NEW",
            description: "Release notes shown to users (max 5000 chars, plain text)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("whats_new must not exceed 5000 characters") if v.length > 5000 }
          ),
          FastlaneCore::ConfigItem.new(
            key:         :moder_info,
            env_name:    "RUSTORE_MODER_INFO",
            description: "Notes for the RuStore moderator, e.g. test credentials (max 180 chars)",
            type:        String,
            optional:    true,
            verify_block: proc { |v| UI.user_error!("moder_info must not exceed 180 characters") if v.length > 180 }
          ),

          # ── Publication ────────────────────────────────────────────────────
          FastlaneCore::ConfigItem.new(
            key:           :publish_type,
            env_name:      "RUSTORE_PUBLISH_TYPE",
            description:   "INSTANTLY — auto-publish after moderation; MANUAL — publish from Console; DELAYED — scheduled via release_date",
            default_value: "INSTANTLY",
            type:          String,
            optional:      true,
            verify_block:  proc { |v| UI.user_error!("publish_type must be INSTANTLY, MANUAL, or DELAYED") unless %w[INSTANTLY MANUAL DELAYED].include?(v) }
          ),
          FastlaneCore::ConfigItem.new(
            key:         :release_date,
            env_name:    "RUSTORE_RELEASE_DATE",
            description: "Scheduled release datetime in ISO 8601 format (only used with DELAYED)",
            type:        String,
            optional:    true
          ),
          FastlaneCore::ConfigItem.new(
            key:         :rollout_percentage,
            env_name:    "RUSTORE_ROLLOUT_PERCENTAGE",
            description: "Staged rollout: allowed values are 5, 10, 25, 50, 75, 100; omit for full rollout",
            type:        Integer,
            optional:    true,
            verify_block: proc { |v|
              UI.user_error!("rollout_percentage must be one of: 5, 10, 25, 50, 75, 100") unless [5, 10, 25, 50, 75, 100].include?(v)
            }
          )
        ]
      end

      def self.description
        "Upload and publish Android apps (APK/AAB) to RuStore app store"
      end

      def self.details
        <<~DETAILS
          Uploads an Android application to the RuStore app store via the RuStore Public API.

          Supports multi-file versions in a single API version:
            - AAB (Google/GMS build) as the main artifact
            - APK (Huawei/HMS build) as a secondary artifact (servicesType=HMS)

          The pipeline always finishes immediately after submitting for moderation.
          Publication behaviour is controlled by publish_type:
            INSTANTLY — RuStore auto-publishes after moderation passes (default)
            DELAYED   — scheduled publication via release_date
            MANUAL    — moderation runs, then publish manually from RuStore Console

          GitLab CI: when GITLAB_CI=true, each step is wrapped in a collapsible
          section visible in the Pipeline web UI.

          Requires at least one active version already published in RuStore Console.
        DETAILS
      end

      def self.authors
        ["Your Org"]
      end

      def self.example_usage
        [
          '# Minimal — AAB only, INSTANTLY (default)',
          'rustore_upload(',
          '  package_name:     "com.example.app",',
          '  key_id:           ENV["RUSTORE_KEY_ID"],',
          '  private_key_path: "rustore_private_key.pem",',
          '  aab_path:         "app/build/outputs/bundle/release/app-release.aab"',
          ')',
          '',
          '# AAB (GMS) + APK (HMS), staged rollout',
          'rustore_upload(',
          '  package_name:       "com.example.app",',
          '  key_id:             ENV["RUSTORE_KEY_ID"],',
          '  private_key:        ENV["RUSTORE_PRIVATE_KEY"],',
          '  aab_path:           "app/build/outputs/bundle/gmsRelease/app-gms-release.aab",',
          '  hms_apk_path:       "app/build/outputs/apk/hmsRelease/app-hms-release.apk",',
          '  publish_type:       "INSTANTLY",',
          '  rollout_percentage: 20',
          ')',
          '',
          '# Scheduled release',
          'rustore_upload(',
          '  package_name: "com.example.app",',
          '  key_id:       ENV["RUSTORE_KEY_ID"],',
          '  private_key:  ENV["RUSTORE_PRIVATE_KEY"],',
          '  aab_path:     "...",',
          '  publish_type: "DELAYED",',
          '  release_date: "2025-03-01T10:00:00+03:00"',
          ')'
        ].join("\n")
      end

      def self.is_supported?(platform)
        platform == :android
      end

      private

      def self.validate_file!(path, param_name, expected_ext, logger)
        unless File.exist?(path)
          logger.error(
            "File not found for #{param_name}: #{path}",
            hint: "Check that the build step ran before rustore_upload and the path is correct"
          )
        end
        ext = File.extname(path).downcase
        unless ext == expected_ext
          logger.error(
            "#{param_name} has unexpected extension '#{ext}' (expected '#{expected_ext}'): #{path}",
            hint: "Make sure you passed the correct file path"
          )
        end
      end
    end
  end
end
