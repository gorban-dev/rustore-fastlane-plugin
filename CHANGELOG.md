# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] — 2026-11-01

### Added

- `rustore_check` action: a dry run that gets a token and reads the app's
  versions, logging up to 5 latest. Uploads nothing and does not touch drafts.
  HTTP 404 on the version list counts as success (the versions API opens after
  the first publication from RuStore Console). Returns the versions Array.
- `RustoreClient#list_versions(package_name:, page_size: 20)` — first page of
  `GET application/{package}/version`; raises `RustoreClient::NotFoundError`
  on HTTP 404.
- A blank or missing private key in `rustore_check` fails with
  `RuStore: private_key или private_key_path не задан` before any request.

### Changed

- `key_id`, `private_key`, `private_key_path` and `package_name` options moved
  to `RustoreOptions.credentials`, shared by both actions. No behaviour change
  for `rustore_upload`.

## [0.3.1] — 2026-10-30

First release published to RubyGems; no behaviour changes since 0.3.0.

### Fixed

- Gem metadata: homepage pointed to a placeholder repository; added source
  code, changelog and bug tracker links; real author name.

## [0.3.0] — 2026-10-30

### Breaking

- Public API host changed to `public-api-m.rustore.ru`, following RuStore's
  domain migration. The old `public-api.rustore.ru` is no longer used.
- Removed `RustoreClient` methods the action never called and whose endpoints
  have changed in the RuStore docs: `wait_for_moderation`, `version_status`,
  `configure_publication`, `publish`, `upload_icon`, `upload_screenshot`.
- Removed `RustoreLogger#progress`; the percentage bar reported bytes handed
  to the socket, not bytes accepted by RuStore.

### Added

- Bundled Russian Trusted Root CA, trusted on top of the system roots for
  plugin requests. Nothing to install on CI runners.
- `upload_timeout` (`RUSTORE_UPLOAD_TIMEOUT`, default 900 s) — how long to wait
  for RuStore to answer an AAB/APK upload. Other requests keep 300 s.
- `update_priority` (`RUSTORE_UPDATE_PRIORITY`, `0`–`5`, default `0`).
- Upload logs: send time, a heartbeat every 60 s while RuStore checks the
  file, response time, permissions and SDKs RuStore detected in the file.
- Readable errors for timeouts, TLS failures, connection failures, 5xx with
  non-JSON bodies and the "new sensitive permissions" / "illegal permissions"
  upload rejections, each with a hint.

### Fixed

- An AAB/APK upload that RuStore answered after more than 300 s failed with a
  raw `Faraday::TimeoutError` stack trace. The wait is now `upload_timeout`
  and a timeout is reported with the file, versionId and a hint.
- The moderation request sent the priority in the JSON body; RuStore expects
  the `priorityUpdate` query parameter, so the value was ignored.
- Existing draft lookup now filters with `versionStatuses=DRAFT` instead of
  scanning the first page of release versions.

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

[0.3.1]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.3.1
[0.3.0]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.3.0
[0.2.0]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.2.0
[0.1.0]: https://github.com/gorban-dev/rustore-fastlane-plugin/releases/tag/v0.1.0
