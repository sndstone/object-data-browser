#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-linux}"
ARCH="${2:-$(uname -m)}"
PACKAGE_FORMAT="${3:-}"
TOOLS_DIR="$ROOT_DIR/.tmp/toolchains"

"$ROOT_DIR/scripts/bootstrap.sh" --arch "$ARCH"

export PATH="$TOOLS_DIR/flutter/bin:$TOOLS_DIR/go/bin:$TOOLS_DIR/cargo/bin:$TOOLS_DIR/java/bin:$TOOLS_DIR/nfpm:$PATH"
export JAVA_HOME="$TOOLS_DIR/java"
export CARGO_HOME="$TOOLS_DIR/cargo"
export RUSTUP_HOME="$TOOLS_DIR/rustup"

ensure_flutter_project() {
  local platforms="$1"
  local app_dir="$ROOT_DIR/apps/flutter_app"
  local needs_create=0

  IFS=',' read -r -a platform_list <<< "$platforms"
  for platform_name in "${platform_list[@]}"; do
    if [[ ! -d "$app_dir/$platform_name" ]]; then
      needs_create=1
      break
    fi
  done

  if [[ ! -f "$app_dir/.metadata" ]]; then
    needs_create=1
  fi

  if [[ "$needs_create" -eq 1 ]]; then
    pushd "$app_dir" >/dev/null
    flutter create \
      --project-name s3_browser_crossplat \
      --org com.example.s3browser \
      --platforms "$platforms" \
      .
    popd >/dev/null
  fi
}

resolve_linux_bundle_dir() {
  if [[ -d "$ROOT_DIR/apps/flutter_app/build/linux/$ARCH/release/bundle" ]]; then
    printf '%s\n' "$ROOT_DIR/apps/flutter_app/build/linux/$ARCH/release/bundle"
    return
  fi

  find "$ROOT_DIR/apps/flutter_app/build/linux" -path '*/release/bundle' -type d | head -n 1
}

resolve_macos_app_dir() {
  find "$ROOT_DIR/apps/flutter_app/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' -type d | head -n 1
}

require_macos_project() {
  local app_dir="$ROOT_DIR/apps/flutter_app"
  if [[ ! -d "$app_dir/macos" ]]; then
    echo "The checked-in macOS Flutter scaffold is missing at $app_dir/macos." >&2
    exit 1
  fi
}

clean_macos_release_artifacts() {
  local release_dir="$ROOT_DIR/apps/flutter_app/build/macos/Build/Products/Release"
  if [[ -d "$release_dir" ]]; then
    find "$release_dir" -maxdepth 1 -name '*.app' -type d -exec rm -rf {} +
  fi
}

pushd "$ROOT_DIR/apps/flutter_app" >/dev/null
case "$PLATFORM" in
  linux)
    ensure_flutter_project "linux"
    flutter pub get
    flutter build linux
    LINUX_BUNDLE_DIR="$(resolve_linux_bundle_dir)"
    popd >/dev/null
    if [[ -z "$LINUX_BUNDLE_DIR" || ! -d "$LINUX_BUNDLE_DIR" ]]; then
      echo "Linux Flutter bundle was not found after build." >&2
      exit 1
    fi
    "$ROOT_DIR/scripts/stage-engines.sh" --release-dir "$LINUX_BUNDLE_DIR" --tools-dir "$TOOLS_DIR" --arch "$ARCH"
    if [[ -n "$PACKAGE_FORMAT" ]]; then
      "$ROOT_DIR/scripts/package-linux.sh" --arch "$ARCH" --format "$PACKAGE_FORMAT"
    fi
    ;;
  macos)
    require_macos_project
    clean_macos_release_artifacts
    flutter pub get
    flutter build macos --release
    MACOS_APP_DIR="$(resolve_macos_app_dir)"
    popd >/dev/null
    if [[ -z "$MACOS_APP_DIR" || ! -d "$MACOS_APP_DIR" ]]; then
      echo "macOS app bundle was not found after build." >&2
      exit 1
    fi
    "$ROOT_DIR/scripts/stage-engines.sh" --release-dir "$MACOS_APP_DIR" --tools-dir "$TOOLS_DIR" --arch "$ARCH"
    codesign --force --sign - "$MACOS_APP_DIR"
    "$ROOT_DIR/scripts/package-macos.sh" --app-bundle "$MACOS_APP_DIR" --arch "$ARCH"
    ;;
  android)
    if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
      popd >/dev/null
      echo "ANDROID_HOME/ANDROID_SDK_ROOT is not set and no Android SDK was found." >&2
      echo "Linux Android builds require a preinstalled Android SDK; scripts/bootstrap.sh does not provision one." >&2
      echo "Install the Android SDK and set ANDROID_HOME (or ANDROID_SDK_ROOT) to its location, then rerun ./scripts/build.sh android." >&2
      exit 1
    fi
    ensure_flutter_project "android"
    flutter pub get
    flutter build apk --release --target-platform android-arm64 --split-per-abi
    flutter build appbundle --release --target-platform android-arm64
    popd >/dev/null
    ;;
  *)
    popd >/dev/null
    echo "Unsupported platform: $PLATFORM" >&2
    exit 1
    ;;
esac
