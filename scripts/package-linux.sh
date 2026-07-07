#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tmp/toolchains"
ARCH="$(uname -m)"
FORMAT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    *)
      echo "Unknown package option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FORMAT" ]]; then
  echo "--format deb|rpm is required" >&2
  exit 1
fi

export PATH="$TOOLS_DIR/nfpm:$PATH"

APP_DIR="$ROOT_DIR/apps/flutter_app/build/linux/${ARCH}/release/bundle"
if [[ ! -d "$APP_DIR" ]]; then
  APP_DIR="$ROOT_DIR/apps/flutter_app/build/linux/x64/release/bundle"
fi
if [[ ! -d "$APP_DIR" ]]; then
  echo "Linux Flutter bundle was not found. Run ./scripts/build.sh linux $ARCH first." >&2
  exit 1
fi

STAGE_DIR="$ROOT_DIR/dist/linux/stage-$FORMAT-$ARCH"
OUTPUT_DIR="$ROOT_DIR/dist/linux"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/usr/lib/object-data-browser" "$STAGE_DIR/usr/bin" "$OUTPUT_DIR"
cp -R "$APP_DIR"/. "$STAGE_DIR/usr/lib/object-data-browser/"
cat >"$STAGE_DIR/usr/bin/object-data-browser" <<'EOF'
#!/usr/bin/env bash
exec /usr/lib/object-data-browser/s3_browser_crossplat "$@"
EOF
chmod +x "$STAGE_DIR/usr/bin/object-data-browser"

NATIVE_ARCH="$ARCH"
case "$FORMAT-$ARCH" in
  deb-x86_64|deb-amd64) NATIVE_ARCH="amd64" ;;
  deb-aarch64|deb-arm64) NATIVE_ARCH="arm64" ;;
  rpm-x86_64|rpm-amd64) NATIVE_ARCH="x86_64" ;;
  rpm-aarch64|rpm-arm64) NATIVE_ARCH="aarch64" ;;
esac

PUBSPEC_PATH="$ROOT_DIR/apps/flutter_app/pubspec.yaml"
APP_VERSION="0.0.0"
if [[ -f "$PUBSPEC_PATH" ]]; then
  PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$PUBSPEC_PATH" | head -n 1)"
  if [[ -n "$PUBSPEC_VERSION" ]]; then
    APP_VERSION="$PUBSPEC_VERSION"
  fi
fi

NFPM_CONFIG="$ROOT_DIR/packaging/linux/nfpm.generated.yaml"
sed \
  -e "s|{{ROOT}}|$STAGE_DIR|g" \
  -e "s|{{ARCH}}|$NATIVE_ARCH|g" \
  -e "s|{{FORMAT}}|$FORMAT|g" \
  -e "s|{{OUTPUT}}|$OUTPUT_DIR|g" \
  -e "s|{{VERSION}}|$APP_VERSION|g" \
  "$ROOT_DIR/packaging/linux/nfpm.yaml.tmpl" >"$NFPM_CONFIG"

nfpm package --config "$NFPM_CONFIG" --packager "$FORMAT" --target "$OUTPUT_DIR"
