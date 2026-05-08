# Android Packaging

Expected artifacts:

- Primary sideloadable APK, copied to:
  `dist/android/object-data-browser-android-<version>-arm64.apk`
- Secondary Android App Bundle, copied to:
  `dist/android/object-data-browser-android-<version>-arm64.aab`

Raw Flutter outputs remain under `build/app/outputs/...` during the build.

Rust and Go mobile adapters are the supported Android engine set. Python and Java are desktop-only.
