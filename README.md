# fastlane-plugin-rustore

Fastlane plugin for publishing Android applications to [RuStore](https://rustore.ru) — the Russian app store — via the [RuStore Public API](https://www.rustore.ru/help/work-with-rustore-api/api-upload-publication-app).

## Features

- Upload **AAB** (Google/GMS, main artifact) and **APK** (Huawei/HMS, secondary) in a single version
- Full publish workflow: authenticate → create draft → upload files → submit for moderation → configure publication
- The pipeline always finishes immediately after submission — no waiting for moderation
- **GitLab CI** collapsible log sections (foldable blocks in Pipeline UI)
- Staged rollout support (`rollout_percentage`)
- Scheduled publishing (`DELAYED` + `release_date`)
- Auto-cleanup of existing drafts before creating a new one
- JWE token auto-refresh (900 s TTL)

## Requirements

- Fastlane ≥ 2.200.0
- Ruby ≥ 2.6
- At least **one active published version** must already exist in RuStore Console (API requirement)

---

## Installation

Add the plugin to your `Pluginfile`:

```ruby
# Pluginfile
gem "fastlane-plugin-rustore"
```

Then run:

```sh
fastlane install_plugins
```

---

## Setup: RuStore API credentials

1. Log in to [RuStore Console](https://console.rustore.ru) with a **company owner** account
2. Go to **Company → API RuStore**
3. Click **Generate a key**, give it a name, select your app and required API methods
4. Download the **private key** (PEM file) — save it securely, RuStore does not store it

You will get two values:
- **Key ID** (`key_id`) — shown in the Console after generation
- **Private key** — the downloaded `.pem` file

---

## Parameters

| Parameter | Env var | Required | Default | Description |
|---|---|---|---|---|
| `key_id` | `RUSTORE_KEY_ID` | yes | — | API key ID from RuStore Console |
| `private_key_path` | `RUSTORE_PRIVATE_KEY_PATH` | one of two | — | Path to RSA private key PEM file |
| `private_key` | `RUSTORE_PRIVATE_KEY` | one of two | — | PEM content as string (for CI secrets) |
| `package_name` | `RUSTORE_PACKAGE_NAME` | yes | — | App package name, e.g. `com.example.app` |
| `aab_path` | `RUSTORE_AAB_PATH` | one of two | — | Path to AAB (Google/GMS — becomes main artifact) |
| `apk_path` | `RUSTORE_APK_PATH` | one of two | — | Path to APK (used when `aab_path` not set) |
| `hms_apk_path` | `RUSTORE_HMS_APK_PATH` | no | — | Path to Huawei/HMS APK (`servicesType=HMS, isMainApk=false`) |
| `publish_type` | `RUSTORE_PUBLISH_TYPE` | no | `INSTANTLY` | `INSTANTLY` / `MANUAL` / `DELAYED` |
| `release_date` | `RUSTORE_RELEASE_DATE` | no | — | ISO 8601 datetime, only for `DELAYED` |
| `rollout_percentage` | `RUSTORE_ROLLOUT_PERCENTAGE` | no | 100% | Staged rollout: 1–100 |

---

## Publish types

| `publish_type` | Behaviour |
|---|---|
| `INSTANTLY` | RuStore auto-publishes after moderation passes (default) |
| `DELAYED` | Scheduled publication via `release_date` in ISO 8601 |
| `MANUAL` | Moderation runs normally; publish manually from RuStore Console |

The pipeline finishes immediately after submitting for moderation for all three types.

---

## Usage examples

### Minimal — AAB only, INSTANTLY (default)

```ruby
# fastlane/Fastfile
lane :deploy_rustore do
  rustore_upload(
    package_name:     "com.example.app",
    key_id:           ENV["RUSTORE_KEY_ID"],
    private_key_path: "fastlane/rustore_private_key.pem",
    aab_path:         "app/build/outputs/bundle/release/app-release.aab"
  )
end
```

### AAB (GMS) + APK (HMS), staged rollout

```ruby
lane :deploy_rustore do
  rustore_upload(
    package_name:       "com.example.app",
    key_id:             ENV["RUSTORE_KEY_ID"],
    private_key:        ENV["RUSTORE_PRIVATE_KEY"],

    # Primary build — Google/GMS (AAB is always isMainApk)
    aab_path:           "app/build/outputs/bundle/gmsRelease/app-gms-release.aab",

    # Secondary build — Huawei/HMS (servicesType=HMS, isMainApk=false)
    hms_apk_path:       "app/build/outputs/apk/hmsRelease/app-hms-release.apk",

    publish_type:       "INSTANTLY",
    rollout_percentage: 20           # release to 20% of users first
  )
end
```

### Scheduled release

```ruby
lane :deploy_rustore_scheduled do
  rustore_upload(
    package_name: "com.example.app",
    key_id:       ENV["RUSTORE_KEY_ID"],
    private_key:  ENV["RUSTORE_PRIVATE_KEY"],
    aab_path:     lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH],
    publish_type: "DELAYED",
    release_date: "2025-03-01T10:00:00+03:00"  # Moscow time
  )
end
```

### Combined with Gradle build

```ruby
lane :build_and_deploy do
  gradle(task: "bundle",   flavor: "gms", build_type: "Release")
  gradle(task: "assemble", flavor: "hms", build_type: "Release")

  rustore_upload(
    package_name: "com.example.app",
    key_id:       ENV["RUSTORE_KEY_ID"],
    private_key:  ENV["RUSTORE_PRIVATE_KEY"],
    aab_path:     lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH],
    hms_apk_path: "app/build/outputs/apk/hmsRelease/app-hms-release.apk",
    publish_type: "INSTANTLY"
  )
end
```

---

## CI/CD integration

### GitLab CI

```yaml
# .gitlab-ci.yml

variables:
  RUSTORE_KEY_ID:      $RUSTORE_KEY_ID       # set in GitLab CI/CD → Variables
  RUSTORE_PRIVATE_KEY: $RUSTORE_PRIVATE_KEY  # set as "File" type variable — path to PEM

stages:
  - build
  - deploy

build:
  stage: build
  script:
    - bundle exec fastlane build_release
  artifacts:
    paths:
      - app/build/outputs/bundle/gmsRelease/
      - app/build/outputs/apk/hmsRelease/
    expire_in: 1 hour

deploy_rustore:
  stage: deploy
  needs: [build]
  script:
    - bundle exec fastlane deploy_rustore
  environment:
    name: production
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/  # run only on version tags
```

```ruby
# fastlane/Fastfile
lane :deploy_rustore do
  rustore_upload(
    package_name:     "com.example.app",
    key_id:           ENV["RUSTORE_KEY_ID"],
    private_key_path: ENV["RUSTORE_PRIVATE_KEY"],  # "File" variable = path to PEM
    aab_path:         "app/build/outputs/bundle/gmsRelease/app-gms-release.aab",
    hms_apk_path:     "app/build/outputs/apk/hmsRelease/app-hms-release.apk",
    publish_type:     "INSTANTLY"
  )
end
```

**Storing the private key in GitLab:**

- Go to **Settings → CI/CD → Variables**
- Add `RUSTORE_KEY_ID` as a regular masked variable
- Add `RUSTORE_PRIVATE_KEY` as **type: File** — GitLab writes the PEM to a temp file and exports the path. Use `private_key_path: ENV["RUSTORE_PRIVATE_KEY"]`
- Alternatively, paste the PEM content as a masked variable and use `private_key: ENV["RUSTORE_PRIVATE_KEY"]`

**GitLab CI log output** (steps appear as collapsible sections):

```
▶ [RuStore] Step 1/6: Authentication              ← click to expand
▶ [RuStore] Step 2/6: Draft Management
▶ [RuStore] Step 3/6: Uploading AAB (GMS/main)
▶ [RuStore] Step 4/6: Uploading APK (HMS/secondary)
▶ [RuStore] Step 5/6: Submitting for moderation
▶ [RuStore] Step 6/6: Configuring publication
[RuStore] ✓ All done! com.example.app versionId=12345 submitted to RuStore.
```

---

### GitHub Actions

```yaml
# .github/workflows/deploy-rustore.yml
name: Deploy to RuStore

on:
  push:
    tags:
      - 'v*'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.2'
          bundler-cache: true

      - name: Build release
        run: bundle exec fastlane build_release

      - name: Deploy to RuStore
        env:
          RUSTORE_KEY_ID:      ${{ secrets.RUSTORE_KEY_ID }}
          RUSTORE_PRIVATE_KEY: ${{ secrets.RUSTORE_PRIVATE_KEY }}
        run: bundle exec fastlane deploy_rustore
```

```ruby
# fastlane/Fastfile
lane :deploy_rustore do
  rustore_upload(
    package_name: "com.example.app",
    key_id:       ENV["RUSTORE_KEY_ID"],
    private_key:  ENV["RUSTORE_PRIVATE_KEY"],  # PEM content from GitHub secret
    aab_path:     "app/build/outputs/bundle/gmsRelease/app-gms-release.aab",
    hms_apk_path: "app/build/outputs/apk/hmsRelease/app-hms-release.apk",
    publish_type: "INSTANTLY"
  )
end
```

**Storing secrets in GitHub:**

- Go to **Settings → Secrets and variables → Actions**
- Add `RUSTORE_KEY_ID` — the key ID string
- Add `RUSTORE_PRIVATE_KEY` — paste the full PEM content (including `-----BEGIN/END PRIVATE KEY-----` lines)

---

### Bitrise

```yaml
# bitrise.yml (relevant step)
- fastlane@3:
    inputs:
    - lane: deploy_rustore
    envs:
    - RUSTORE_KEY_ID: $RUSTORE_KEY_ID
    - RUSTORE_PRIVATE_KEY: $RUSTORE_PRIVATE_KEY
```

Add `RUSTORE_KEY_ID` and `RUSTORE_PRIVATE_KEY` as **Secret Environment Variables** in Bitrise **Secrets** tab.

---

## Multi-file versions

RuStore allows up to **1 AAB + 8 APK** (or 10 APK) files per version. The plugin supports the most common scenario:

```
Version
├── app-gms-release.aab   ← AAB, servicesType=Unknown, isMainApk=true (implicit)
└── app-hms-release.apk   ← APK, servicesType=HMS,     isMainApk=false
```

RuStore automatically serves the appropriate file to each user based on their device.

---

## Debugging

Enable verbose HTTP logging:

```sh
RUSTORE_DEBUG=1 bundle exec fastlane deploy_rustore
```

Run Fastlane with full verbose output:

```sh
bundle exec fastlane deploy_rustore --verbose
```

---

## Error reference

| Error | Cause | Fix |
|---|---|---|
| `Authentication failed: ...` | Wrong `key_id` or corrupted key | Check key in RuStore Console → API RuStore |
| `Failed to load RSA private key` | Invalid PEM format | Ensure the key includes `-----BEGIN/END PRIVATE KEY-----` |
| `API request failed [404]` | Package not found | Verify `package_name`; at least 1 active version must exist in RuStore Console |
| `API request failed [403]` | Key lacks permissions | Ensure the key has access to the required API methods for your app in Console |
| `version_code must be greater than current active` | Old build uploaded | Increment `versionCode` in `build.gradle` |
| `Moderation declined` | RuStore reviewer rejected the update | Check reviewer comments in RuStore Console |

---

## Development

```sh
git clone https://github.com/your-org/fastlane-plugin-rustore
cd fastlane-plugin-rustore
bundle install
bundle exec rspec                         # run tests
bundle exec rspec --format documentation  # verbose output
```

---

## License

MIT
