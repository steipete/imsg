#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="imsg"
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"Developer ID Application: Peter Steinberger (Y5PE65HELJ)"}
ENTITLEMENTS="${ROOT}/Resources/imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
ZIP_PATH="${OUTPUT_DIR}/imsg-macos.zip"
DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-dist.XXXXXX")"
API_KEY_FILE="$(mktemp "/tmp/${APP_NAME}-notary.XXXXXX.p8")"

cleanup() {
  rm -f "$API_KEY_FILE"
  rm -rf "$DIST_DIR"
}
trap cleanup EXIT

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_FILE"

swift build -c release --product imsg

codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$ROOT/.build/release/imsg"

cp "$ROOT/.build/release/imsg" "$DIST_DIR/imsg"
for bundle in "$ROOT/.build/release"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

chmod -R u+rw "$DIST_DIR"
xattr -cr "$DIST_DIR"
find "$DIST_DIR" -name '._*' -delete

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
(
  cd "$DIST_DIR"
  "$DITTO_BIN" --norsrc -c -k . "$ZIP_PATH"
)

xcrun notarytool submit "$ZIP_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

codesign --verify --strict --verbose=4 "$DIST_DIR/imsg"
spctl -a -t exec -vv "$DIST_DIR/imsg"

echo "Done: $ZIP_PATH"
