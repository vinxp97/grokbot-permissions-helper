#!/usr/bin/env bash
# Build Grokbot Permissions Helper.app on macOS 14+.
# Usage: ./scripts/build.sh [optional/output/path.app]
#
# BUNDLE_ID env override (default com.grokbot.permissionshelper).
# Vinman's live install already has TCC under a different id; keep grants with:
#   BUNDLE_ID=com.vincentderiu.grokbotpermissionshelper ./scripts/build.sh
# The public repo Info.plist default stays com.grokbot.permissionshelper.
# Do not commit a live bundle id change; override at build time only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.grokbot.permissionshelper}"
EXEC_NAME="GrokbotPermissionsHelper"
DEFAULT_OUT="$ROOT/dist/Grokbot_Permissions_Helper.app"
OUT="${1:-$DEFAULT_OUT}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This app must be compiled on macOS (needs AppKit, EventKit, Contacts, Network)." >&2
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

shopt -s nullglob
SWIFT_FILES=("$ROOT/Sources/GrokbotPermissionsHelper/"*.swift)
if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
  echo "No Swift sources under Sources/GrokbotPermissionsHelper" >&2
  exit 1
fi

swiftc \
  -O \
  -sdk "$SDK" \
  -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
  -framework AppKit \
  -framework EventKit \
  -framework Contacts \
  -framework Security \
  -framework Network \
  -o "$MACOS/$EXEC_NAME" \
  "${SWIFT_FILES[@]}"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$CONTENTS/Info.plist"
else
  python3 -c "
import pathlib, sys
p = pathlib.Path(sys.argv[1])
bid = sys.argv[2]
text = p.read_text(encoding='utf-8')
old = '<key>CFBundleIdentifier</key>\n  <string>com.grokbot.permissionshelper</string>'
new = '<key>CFBundleIdentifier</key>\n  <string>%s</string>' % bid
if old not in text:
    raise SystemExit('CFBundleIdentifier block not found in Info.plist')
p.write_text(text.replace(old, new, 1), encoding='utf-8')
" "$CONTENTS/Info.plist" "$BUNDLE_ID"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Ad-hoc sign with a stable identifier so TCC grants stick across rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"

echo "Built $OUT"
echo "Bundle id: $BUNDLE_ID"
echo "Install: cp -R \"$OUT\" ~/Applications/"
echo "First run: open \"$OUT\"   (click Allow on Calendar, Contacts, Reminders)"
echo "Mail setup: \"$MACOS/$EXEC_NAME\" --mail-setup"
