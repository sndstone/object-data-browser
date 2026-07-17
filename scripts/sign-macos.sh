#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-}"
IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
TEAM_ID="${MACOS_TEAM_ID:-}"
PROVISIONING_PROFILE="${MACOS_PROVISIONING_PROFILE:-}"
TEMPLATE="$ROOT_DIR/packaging/macos/DeveloperID.entitlements.template"

if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" || "$APP_BUNDLE" != *.app ]]; then
  echo "Usage: MACOS_SIGNING_IDENTITY=... MACOS_TEAM_ID=... MACOS_PROVISIONING_PROFILE=... ./scripts/sign-macos.sh <app-bundle>" >&2
  exit 1
fi

for value_name in IDENTITY TEAM_ID PROVISIONING_PROFILE; do
  if [[ -z "${!value_name}" ]]; then
    echo "Developer ID signing requires $value_name." >&2
    exit 1
  fi
done

if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "The Developer ID provisioning profile was not found at $PROVISIONING_PROFILE." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "The requested code-signing identity is not installed: $IDENTITY" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/object-browser-sign.XXXXXX")"
ENTITLEMENTS="$TMP_DIR/DeveloperID.entitlements"
PROFILE_PLIST="$TMP_DIR/provisioning-profile.plist"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

sed "s/__TEAM_ID__/$TEAM_ID/g" "$TEMPLATE" > "$ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null
security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.application-identifier' \
  "$PROFILE_PLIST")"
if [[ "$PROFILE_APP_ID" != "$TEAM_ID.com.example.s3BrowserCrossplat" ]]; then
  echo "Provisioning profile authorizes $PROFILE_APP_ID, expected $TEAM_ID.com.example.s3BrowserCrossplat." >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:keychain-access-groups' \
  "$PROFILE_PLIST" | grep -Fq "$TEAM_ID.com.example.s3BrowserCrossplat"; then
  echo "Provisioning profile does not authorize the required Keychain access group." >&2
  exit 1
fi
cp "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"

# First replace all ad-hoc nested signatures. The final pass applies the
# provisioned Keychain identity only to the main app target.
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  "$APP_BUNDLE"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_BUNDLE" 2>&1)"
grep -Fq "$TEAM_ID.com.example.s3BrowserCrossplat" <<< "$SIGNED_ENTITLEMENTS"
grep -Fq 'keychain-access-groups' <<< "$SIGNED_ENTITLEMENTS"
echo "Signed macOS app with stable Developer ID Keychain identity."
