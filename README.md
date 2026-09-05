# Object Data Browser

`object-data-browser` is a cross-platform object storage browser monorepo. It contains:

- A Flutter app shell for Windows, macOS, Linux, Android, and iOS
- A versioned engine contract shared by Python, Go, Rust, and Java backends
- Packaging and bootstrap scripts that fetch toolchains into a local temp cache
- Contract fixtures and implementation documentation

## Layout

```text
object-data-browser/
├── apps/flutter_app
├── contracts
├── docs
├── engines
├── packaging
├── scripts
└── tests
```

## Current Status

This repository now includes:

- The initial Flutter application scaffold with adaptive Browser, Benchmark, and Settings workspaces
- Endpoint profiles for S3-compatible targets, AWS S3, and Azure Blob Storage (account name + access key; implemented in the Go and Python engines, see `docs/FEATURE_MATRIX.md`)
- Unified responsive breakpoints (phone < 700 px, tablet < 1 000 px, compact desktop < 1 360 px, desktop >= 1 360 px) that apply equally to resized desktop windows
- Bounded persistent sidecar pools (four processes globally, two per engine, with a cancellable 64-request queue)
- The shared domain models and engine interface expected by all backends
- Fully implemented Python, Go, Rust, and Java engines behind a shared contract, with parallel multipart transfers and native inspector tools (see `CHANGELOG.md` 2.1.0-2.2.4)
- Dynamic S3 upload part sizing that keeps parallel uploads within the 5 MiB–5 GiB part range and 10 000-part limit, with a manual override in Settings
- Update-stable, Developer ID-backed macOS credential persistence with a migration path from older Keychain items, plus expandable previews with selectable syntax highlighting, image pan/zoom, and static HTML page rendering
- Build/bootstrap scripts that stage dependencies into `.tmp` under the repo root
- An iOS 13+ target backed by the official AWS SDK for Swift, with S3 browsing,
  object operations, transfers, Files.app downloads, profile export sharing,
  local-network access, and Keychain credential storage

## Bootstrap

Linux/macOS:

```bash
./scripts/bootstrap.sh
./scripts/build.sh linux
./scripts/build.sh ios arm64
```

Windows PowerShell:

```powershell
.\scripts\build.ps1
.\scripts\build.ps1 -Platform windows
.\scripts\build.ps1 -Platform windows -IncludeEngineToolchains
.\scripts\build.ps1 -Platform android
```

The bootstrap scripts do not rely on system-installed Flutter, Go, Rust, or Java. They create a repo-local cache under `.tmp/toolchains` and reuse it across builds.

Windows builds now handle the symlink prerequisite in the same script. If Developer Mode is off, `build.ps1` will prompt for elevation and rerun itself automatically.

Windows desktop packaging also stages the Python, Go, Rust, and Java sidecars into the app bundle, so those toolchains are bootstrapped during a Windows build by default. Use `-IncludeEngineToolchains` when you want those extra backend toolchains staged for other targets too.

Windows Android builds also stage an Android SDK under `.tmp/toolchains/android-sdk`, accept licenses, sign the release output with the debug key for sideloading, and copy the primary arm64 APK to `dist/android/object-data-browser-android-<version>-arm64.apk`. The Android App Bundle remains available as a secondary artifact in `dist/android/`.

Linux Android builds (`./scripts/build.sh android`) do not provision an Android SDK — `scripts/bootstrap.sh` only stages Flutter, Python, Go, Rust, Java, and nfpm. You must have a preinstalled Android SDK with `ANDROID_HOME` or `ANDROID_SDK_ROOT` set before running a Linux Android build; the script fails fast with an actionable error if neither is set. CI relies on the GitHub-hosted runner image's preinstalled SDK.

iOS builds require macOS and Xcode. Without Apple signing configuration,
`./scripts/build.sh ios arm64` produces an unsigned device bundle for compile
verification. Set `IOS_SIGNING_IDENTITY` and `IOS_TEAM_ID` after installing the
matching distribution certificate and provisioning profile to export an IPA.
The first iOS release supports the Browser and Settings workflows; benchmark
and bucket-encryption mutations remain capability-gated.

For simulator testing, open `apps/flutter_app/ios/Runner.xcworkspace` and run
the `Runner` scheme from Xcode. Directly launching an unsigned simulator `.app`
does not supply a usable Keychain entitlement on current iOS runtimes, so it is
suitable for compile/UI checks but cannot persist endpoint credentials.

## 2.2.5 architecture and verification

The desktop adapter uses real Python, Go, Rust, and Java sidecars. Python and
Java route live transfer controls to the job-owning process; sequential Go and
Rust engines deliberately report those controls as unsupported. MockEngineService
is a test/demo implementation, not a production storage fallback.

Browser rows are lazy, with separate inspection focus and batch selection.
Column headers sort and toggle direction; less frequent view tools expand into
an icon tray. Multi-file uploads appear as one parent job, but dispatch each file
separately with its own part size and bounded part workers. Per-file outcomes are
nested in Event Log; cancelling stops queued files and requests cancellation of
the active file when its engine supports it.
ObjectSelection, ObjectQuery, AtomicMetadataStore, and BrowserWorkspaceFrame
separate selection, isolated filtering, metadata persistence, and rebuild scope.
Listing windows stop at 100,000 keys or 16 million key characters. Large queries
and regex run off the UI isolate with a two-second execution deadline. Density
is independent of text scale; short slide/fade transitions respect reduced motion.

Run `flutter analyze` and `flutter test` from `apps/flutter_app`. Run
`REQUIRE_ENGINE=1 ENGINE_CMD="<engine command>" python -m pytest tests/contract -q`
for each desktop engine. CI builds all four engines and runs loopback S3/Azure
failure and pagination fixtures; missing required binaries fail verification.
These deterministic fixtures do not replace real-provider integration testing.

See [implementation and validation details](docs/2.2.5-implementation.md) and
the [visual improvement plan](docs/improvement-plan.html). Public Apple releases
still require the documented signing, provisioning, notarization, and physical
device Keychain/local-network checks.

### 2.2.6 GUI improvements

The GUI plan implementation and verification notes are recorded in
[the 2.2.6 ledger](docs/2.2.6-gui-implementation.md). The application is 2.2.6+1;
the unchanged bundled engine implementations remain 2.2.5.

The [2.2.6 release](https://github.com/sndstone/object-data-browser/releases/tag/v2.2.6)
provides Windows x64/ARM64 MSI installers, Linux x64/ARM64 DEB and RPM packages,
and an Android ARM64 **test** APK for sideloading on Android 7.0+ (API 24+). Android artifacts use a debug
signing key; a different build may require reinstallation rather than an in-place
upgrade. The test AAB is a secondary build artifact, not directly installable.
Public macOS and iOS packages still require the Apple release configuration above.

The Release Matrix workflow can select Windows/Linux with `build_desktop` and
Android independently with `build_android`; `build_mobile` includes both Android
and iOS. Mobile builds bootstrap tools for the host architecture and cross-compile
the ARM64 app. Release checksums are supplied in `SHA256SUMS`.
