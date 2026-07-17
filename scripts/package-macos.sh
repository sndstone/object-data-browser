#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
ARCH="$(uname -m)"
OUTPUT_DIR="$ROOT_DIR/dist/macos"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      APP_BUNDLE="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown macOS packaging option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APP_BUNDLE" ]]; then
  echo "Usage: ./scripts/package-macos.sh --app-bundle <path-to-app> [--arch <arch>] [--output-dir <dir>]" >&2
  exit 1
fi

if [[ ! -d "$APP_BUNDLE" || "$APP_BUNDLE" != *.app ]]; then
  echo "macOS app bundle was not found at $APP_BUNDLE." >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "The 'hdiutil' command is required to package a macOS DMG." >&2
  exit 1
fi

APP_NAME="$(basename "$APP_BUNDLE" .app)"
DMG_NAME="${APP_NAME}-${ARCH}.dmg"
mkdir -p "$OUTPUT_DIR"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/s3-browser-dmg.XXXXXX")"
STAGING_DIR="$TMP_ROOT/stage"
TMP_DMG="$TMP_ROOT/${APP_NAME}-${ARCH}-temp.dmg"
FINAL_DMG="$OUTPUT_DIR/$DMG_NAME"
VOLUME_NAME="$APP_NAME"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$FINAL_DMG"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  "$TMP_DMG" >/dev/null

hdiutil verify "$TMP_DMG" >/dev/null
mv "$TMP_DMG" "$FINAL_DMG"
echo "Packaged macOS DMG at $FINAL_DMG"
