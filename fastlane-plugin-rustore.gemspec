lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fastlane/plugin/rustore/version"

Gem::Specification.new do |spec|
  spec.name          = "fastlane-plugin-rustore"
  spec.version       = Fastlane::RuStore::VERSION
  spec.author        = "RuStore Plugin Contributors"
  spec.email         = ""

  spec.summary       = "Fastlane plugin for publishing Android apps to RuStore"
  spec.description   = <<~DESC
    Upload and publish Android applications (APK/AAB) to RuStore app store via
    the RuStore Public API. Supports multi-file versions: AAB (Google/GMS) as
    main file + APK (Huawei/HMS) as secondary, staged rollouts, and full
    CI/CD logging including GitLab CI collapsible sections.
  DESC
  spec.homepage      = "https://github.com/your-org/fastlane-plugin-rustore"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.6"

  spec.add_dependency "fastlane",          ">= 2.200.0"
  # faraday: no upper version pin — lets fastlane's faraday (~> 1.0) resolve
  spec.add_dependency "faraday",           ">= 1.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"

  spec.add_development_dependency "bundler",  ">= 1.17.3"
  spec.add_development_dependency "rspec",    "~> 3.12"
  spec.add_development_dependency "webmock",  "~> 3.18"
end
