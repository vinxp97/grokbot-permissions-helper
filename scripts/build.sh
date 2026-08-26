#!/usr/bin/env bash
# Build Grokbot Permissions Helper.app on macOS 14+.
# Usage: ./scripts/build.sh [optional/output/path.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.grokbot.permissionshelper"
EXEC_NAME="GrokbotPermissionsHelper"
DEFAULT_OUT="$ROOT/dist/Grokbot_Permissions_Helper.app"
OUT="${1:-$DEFAULT_OUT}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This app must be compiled on macOS (needs AppKit, EventKit, Contacts)." >&2
  exit 1
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export MACOSX_DEPLOYMENT_TARGET

CONTENTS="$OUT/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
rm -rf "$OUT"
mkdir -p "$MACOS" "$RES"

swiftc \
  -O \
  -sdk "$SDK" \
  -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
  -framework AppKit \
  -framework EventKit \
  -framework Contacts \
  -o "$MACOS/$EXEC_NAME" \
  "$ROOT/Sources/GrokbotPermissionsHelper/main.swift"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Ad-hoc sign with a stable identifier so TCC grants stick across rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"

echo "Built $OUT"
echo "Install: cp -R \"$OUT\" ~/Applications/"
echo "First run: open \"$OUT\"   (click Allow on Calendar, Contacts, Reminders)"
