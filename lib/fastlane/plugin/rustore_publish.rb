require "fastlane/plugin/rustore_publish/version"

module Fastlane
  module RustorePublish
    # Returns all actions in the plugin
    def self.all_classes
      Dir[File.expand_path("rustore_publish/**/*.rb", __dir__)]
    end
  end
end

# Autoload all actions and helpers
Fastlane::RustorePublish.all_classes.each { |c| require(c) }
