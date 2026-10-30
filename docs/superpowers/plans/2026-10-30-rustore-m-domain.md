# RuStore -m domain + upload diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the plugin to `public-api-m.rustore.ru` with the Russian Trusted Root CA, align calls with the current RuStore API docs, and make CI logs explain upload failures.

**Architecture:** `RustoreEndpoint` owns host and TLS trust. `RustoreClient` wraps every Faraday call in one network-error handler and replaces the percentage progress bar with send/wait/response timing. The action exposes `upload_timeout` and `update_priority`.

**Tech Stack:** Ruby ≥ 2.6 (CI: 3.0.1), Faraday 1.10.x + faraday-multipart, Net::HTTP (auth), RSpec + WebMock.

**Spec:** decisions agreed in chat on 2026-10-30, summarised below; API reference — https://www.rustore.ru/help/work-with-rustore-api/api-upload-publication-app (fetched 2026-10-30), news https://www.rustore.ru/developer/blog/rustore-obnovlyaet-sertifikaty-i-domeny-chto-nuzhno-sdelat-razrabotchikam (17.09.2026).

## Decisions

- Host is `public-api-m.rustore.ru` only. No fallback to the old host, no ENV override.
- TLS trust = system roots + bundled `certs/russian_trusted_root_ca.crt` (SHA-256 `D2:6D:2D:02:31:B7:C3:9F:92:CC:73:85:12:BA:54:10:35:19:E4:40:5D:68:B5:BD:70:3E:97:88:CA:8E:CF:31`).
- No automatic retries.
- `upload_timeout` param, env `RUSTORE_UPLOAD_TIMEOUT`, Integer > 0, default 900. Other requests keep 300 s.
- Progress percentage removed. Upload logs: start (name, size), "sent in X s, waiting for RuStore to process", heartbeat every 60 s "waiting for RuStore response: N / T s", "response in N s", permissions and SDKs from the response body.
- Network errors (timeout, TLS, connection/DNS) and 5xx-with-HTML become `logger.error` with an actionable hint mentioning versionId and that a rerun is safe.
- `commit` sends `priorityUpdate` as a query param. New param `update_priority`, env `RUSTORE_UPDATE_PRIORITY`, Integer 0..5, default 0 (what RuStore effectively applies today).
- `find_existing_draft` queries `?versionStatuses=DRAFT`.
- Hints for 400 "new sensitive permissions" (upload via Console and fill the permission declaration) and "illegal permissions" (remove and re-upload).
- Dead code removed: `wait_for_moderation`, `version_status`, `configure_publication`, `publish`, `upload_icon`, `upload_screenshot`, `put`, moderation constants, `RustoreLogger#progress` and its helpers.
- New draft fields (privacy*, packageSdkDto, inAppPurchaseTypes, TV, video) — out of scope.
- Log text stays in English, like the rest of the plugin.

## Global Constraints

- Ruby 2.6 syntax compatible (no endless methods, no `=>` pattern matching).
- ConfigItem descriptions must not end with `.`.
- `FastlaneError` raised via `logger.error`; specs use `raising_logger_double`.
- Faraday paths stay relative (no leading `/`).
- Specs: `PATH=/opt/homebrew/opt/ruby@3.3/bin:$PATH bundle exec rspec`.
- No trailing blank lines added to files; no Co-Authored-By in commits.

## Review Focus

- Missing CA file → `Errno::ENOENT` surfaces, not swallowed (Task 1 test).
- Timeout during upload → message names the file, timeout value, versionId, `upload_timeout` (Task 2 test).
- 504 with HTML body → status and "RuStore-side failure" hint, no JSON noise (Task 2 test).
- Heartbeat thread is always stopped, also when the request raises (Task 2 test: no live threads after error).
- Auth over TLS failure → hint about the Russian Trusted Root CA (Task 3 test).

---

### Task 1: RustoreEndpoint without override

**Files:**
- Modify: `lib/fastlane/plugin/rustore_publish/helper/rustore_endpoint.rb`
- Create: `spec/unit/rustore_endpoint_spec.rb`

**Interfaces:**
- Produces: `RustoreEndpoint::HOST`, `::BASE_URL`, `::AUTH_URL` (Strings), `RustoreEndpoint.cert_store -> OpenSSL::X509::Store`.

- [ ] Tests: `BASE_URL == "https://public-api-m.rustore.ru/public/v1"`, `AUTH_URL == "https://public-api-m.rustore.ru/public/auth"`; `cert_store.verify(bundled root)` is true; with `CA_FILE` stubbed to a missing path `cert_store` raises `Errno::ENOENT`.
- [ ] Replace `host`/`base_url`/`auth_url` methods with constants; drop ENV mention from the comment.
- [ ] Update `rustore_client.rb` and `rustore_auth.rb` call sites; run full suite.

### Task 2: Client — network errors, upload logging, API alignment

**Files:**
- Modify: `lib/fastlane/plugin/rustore_publish/helper/rustore_client.rb`
- Modify: `lib/fastlane/plugin/rustore_publish/helper/rustore_logger.rb` (remove `progress`, `build_bar`, `fmt_bytes`, `BAR_WIDTH`)
- Modify: `spec/unit/rustore_client_spec.rb`, `spec/unit/rustore_logger_spec.rb`, `spec/spec_helper.rb` (drop `progress:` from double)

**Interfaces:**
- Produces: `RustoreClient.new(auth:, logger: nil, upload_timeout: DEFAULT_UPLOAD_TIMEOUT, wait_log_interval: 60)`; `DEFAULT_UPLOAD_TIMEOUT = 900`; `submit_for_review(package_name:, version_id:, update_priority: 0)`; `upload_aab`/`upload_apk` return the parsed body (Hash).

- [ ] Tests:
  - `find_existing_draft` requests `version?versionStatuses=DRAFT`.
  - `submit_for_review(update_priority: 3)` posts to `commit?priorityUpdate=3`.
  - `upload_aab` with stub `to_timeout` → error message includes `"did not respond"`, `"900s"`, `"version 42"`; hint includes `upload_timeout`; `Thread.list.size` unchanged after.
  - `to_raise(Faraday::SSLError)` on GET → hint includes `"Russian Trusted Root CA"`.
  - `to_raise(Faraday::ConnectionFailed)` → message includes `"Could not connect"` and host.
  - 504 with HTML body → message includes `"[504]"`, hint includes `"RuStore side"`, no HTML.
  - 400 `"APK/AAB contains new sensitive permissions: [...]"` → hint includes `"RuStore Console"`.
  - Upload success with `permissions`/`autoDetectedSdks` → `logger.info` called with permission names and `"ads: com.google.android.gms.ads"`.
  - Heartbeat: `wait_log_interval: 0.05`, delayed stub response → `info` received with `/Waiting for RuStore response/`.
- [ ] Implement: private `with_network_errors(path, upload: nil) { ... }` rescuing `Faraday::SSLError`, `Faraday::TimeoutError`, `Faraday::ConnectionFailed` (order matters, SSLError first); `upload_file` records send-finish time via a `ProgressIO` on-complete callback, runs heartbeat thread from that moment, kills it in `ensure`; 5xx non-JSON handling and permission hints in `handle_response`/`error_hint`; remove dead code listed in Decisions.
- [ ] Run full suite.

### Task 3: Auth network errors

**Files:**
- Modify: `lib/fastlane/plugin/rustore_publish/helper/rustore_auth.rb`
- Modify: `spec/unit/rustore_auth_spec.rb`

- [ ] Tests: `to_raise(OpenSSL::SSL::SSLError)` → hint includes `"Russian Trusted Root CA"`; `to_timeout` → message includes `"did not respond"`; `to_raise(SocketError)` → `"Could not connect"`.
- [ ] Rescue `OpenSSL::SSL::SSLError`, `Net::OpenTimeout`, `Net::ReadTimeout`, `SocketError`, `SystemCallError` around `Net::HTTP.start`.

### Task 4: Action params, docs, version

**Files:**
- Modify: `lib/fastlane/plugin/rustore_publish/actions/rustore_upload.rb`, `spec/actions/rustore_upload_action_spec.rb`
- Modify: `README.md`, `CHANGELOG.md`, `lib/fastlane/plugin/rustore_publish/version.rb` → `0.3.0`

**Interfaces:**
- Consumes: `RustoreClient.new(..., upload_timeout:)`, `submit_for_review(..., update_priority:)`.

- [ ] Tests: default run posts `commit?priorityUpdate=0`; `update_priority: 6` and `upload_timeout: 0` fail verification.
- [ ] Add ConfigItems `upload_timeout` (Integer, default 900, > 0) and `update_priority` (Integer, default 0, 0..5); pass them through; drop the `/publish-settings` PUT assertion only if it no longer applies.
- [ ] README: host + certificate section, new params, error reference rows (timeout, TLS, 504, sensitive permissions); remove "configure publication" from features. CHANGELOG 0.3.0 entry.
- [ ] Full suite, then a run under Ruby 3.0 / Faraday 1.10 if available locally.
