require "fastlane/plugin/rustore/version"

module Fastlane
  module RuStore
    # Returns all actions in the plugin
    def self.all_classes
      Dir[File.expand_path("rustore/**/*.rb", __dir__)]
    end
  end

  # Fastlane resolves plugin modules by camelizing the gem name suffix,
  # so fastlane-plugin-rustore → Fastlane::Rustore. Alias for compatibility.
  Rustore = RuStore
end

# Autoload all actions and helpers
Fastlane::RuStore.all_classes.each { |c| require(c) }
