# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-05-13

### Breaking

- **Gem renamed** from `fastlane-plugin-rustore` to `fastlane-plugin-rustore_publish`.
  Update your `Pluginfile` to `gem "fastlane-plugin-rustore_publish"`. The bare
  `fastlane-plugin-rustore` name was already taken on RubyGems by an unrelated
  plugin (v0.3.0), which caused spurious "plugin update available" messages in
  CI/CD logs.

### Added

- Support for RuStore Draft API v2 fields in the `rustore_upload` action. Each
  is an optional parameter validated via `verify_block`; when unset, RuStore
  inherits the value from the previously active version.
  - `developer_contacts` — Hash with `email`, `website`, `vk_community`.
    Sub-keys normalized to the API's camelCase (`vk_community` → `vkCommunity`).
    Accepts both Symbol and String keys.
  - `app_name` — max 50 chars
  - `app_type` — `GAMES` or `MAIN`
  - `age_legal` — `0+`, `6+`, `12+`, `16+`, `18+`
  - `short_description` — max 80 chars
  - `full_description` — max 4000 chars
  - `price_value` — kopecks as string of digits, e.g. `"8799"`
  - `categories` — up to 2 strings
  - `seo_tag_ids` — up to 5 integers
  - `faq` — up to 10 items, each `{ question: ≤120 chars, answer: ≤500 chars }`

### Fixed

- `API request failed [400]: Developer contacts are not filled in` from
  RuStore's create-draft endpoint when company developer contacts have not
  been pre-configured in RuStore Console. Pass `developer_contacts:` in your
  Fastfile to satisfy the API requirement.
- Stale GitLab CI log example in README (showed 6 steps; actual workflow has
  5 since the publish-settings step was inlined).

### Preserved (no changes — backward compatible)

- Action name: `rustore_upload`
- Environment variables: `RUSTORE_*`
- Helper class names: `RustoreUploadAction`, `RustoreAuth`, `RustoreClient`,
  `RustoreLogger`
- Branding strings: `[RuStore]` log prefix, RuStore URLs

### Internal

- Ruby module namespace renamed `Fastlane::RuStore` → `Fastlane::RustorePublish`
  (matches the gem-suffix camelization convention so the fastlane plugin loader
  resolves it cleanly without compatibility aliases).
- Test suite: 55 → 85 examples, 0 failures. Includes a regression test that
  locks the original 3-key draft request shape, per-param validation tests,
  and a full-coverage integration test exercising all 10 new fields together.

## [0.1.0]

- Initial release: authenticate via RSA-SHA512 JWE token, create draft, upload
  AAB and HMS APK, submit for moderation. Multi-file versions, staged rollout,
  scheduled releases, GitLab CI collapsible log sections.

[0.2.0]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.2.0
[0.1.0]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.1.0
