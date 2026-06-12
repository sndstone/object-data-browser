# Object Data Browser

`object-data-browser` is a greenfield cross-platform object data browser monorepo. It contains:

- A Flutter app shell for Windows, macOS, Linux, and Android
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
- Unified responsive breakpoints (phone < 700 px, tablet < 1200 px, desktop >= 1200 px) that apply equally to resized desktop windows
- Persistent sidecar engine processes (one long-lived process per engine instead of one per request)
- The shared domain models and engine interface expected by all backends
- Mock engine wiring so the UI shell is functional before the real engines are completed
- Language-specific engine stubs for Python, Go, Rust, and Java
- Build/bootstrap scripts that stage dependencies into `.tmp` under the repo root

## Bootstrap

Linux/macOS:

```bash
./scripts/bootstrap.sh
./scripts/build.sh linux
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

## Immediate Next Steps

1. Replace the mock engine with the first real desktop sidecar implementation.
2. Flesh out the contract test runner against MinIO and AWS S3.
3. Wire the desktop build scripts to signed packaging infrastructure for your target environments.
