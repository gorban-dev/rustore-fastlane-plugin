require "fastlane_core"

module Fastlane
  module RustorePublish
    # Options shared by all RuStore actions: API key and package name.
    module RustoreOptions
      def self.credentials
        [
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
          FastlaneCore::ConfigItem.new(
            key:         :package_name,
            env_name:    "RUSTORE_PACKAGE_NAME",
            description: "Application package name (e.g. com.example.app)",
            type:        String,
            optional:    false
          )
        ]
      end

      # Returns the PEM from private_key or private_key_path. Fails before any
      # request when neither is set or the key is blank, so an empty CI
      # variable does not end up as an OpenSSL error.
      def self.private_key!(params)
        key = params[:private_key].to_s
        key = File.read(params[:private_key_path]) if key.strip.empty? && params[:private_key_path]
        UI.user_error!("RuStore: private_key или private_key_path не задан") if key.to_s.strip.empty?
        key
      end
    end
  end
end