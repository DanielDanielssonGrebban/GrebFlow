#!/bin/zsh
# Builds GrebFlowClaude and runs it from one fixed path, build/GrebFlowClaude.app.
#
# macOS ties microphone, Input Monitoring, and Accessibility approval to the
# app's bundle ID and signature, so always launch this copy rather than the
# one inside DerivedData.
#
#   scripts/run.sh          build (Release), install to build/GrebFlowClaude.app, launch
#   scripts/run.sh --test   run the unit tests first
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
TARGET="$ROOT/build/GrebFlowClaude.app"

if [[ "${1:-}" == "--test" ]]; then
  xcodebuild -project GrebFlowClaude.xcodeproj -scheme GrebFlowClaude -configuration Debug \
    -derivedDataPath "$DERIVED" test | grep -E "✔|✘|error:|TEST" || true
fi

xcodebuild -project GrebFlowClaude.xcodeproj -scheme GrebFlowClaude -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true

BUILT="$DERIVED/Build/Products/Release/GrebFlowClaude.app"
[[ -d "$BUILT" ]] || { echo "Build failed"; exit 1; }

# Stop the previously installed copy (this exact path only) so the new
# build takes its place instead of `open` reactivating the old process.
if pgrep -f "$TARGET/Contents/MacOS/GrebFlowClaude" >/dev/null; then
  pkill -TERM -f "$TARGET/Contents/MacOS/GrebFlowClaude" || true
  sleep 1
fi

rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
codesign --verify --strict "$TARGET"
echo "Signed by: $(codesign -dv --verbose=2 "$TARGET" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2)"

open "$TARGET" --args --dashboard
echo "GrebFlowClaude is running from $TARGET. The dashboard opens on Settings; the menu bar icon is a microphone with a C badge."
