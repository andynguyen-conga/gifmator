#!/usr/bin/env bash
#
# Builds Gifmator.app from the SwiftPM release binary + scripts/Info.plist.in.
# Idempotent — wipes any stale Gifmator.app before writing a fresh one.
# Pass VERSION=... to override the Info.plist version strings (default 0.1.0).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-0.1.0}"
APP="Gifmator.app"
BINARY_NAME="Gifmator"
PLIST_TEMPLATE="scripts/Info.plist.in"
ICON_SOURCE="scripts/AppIcon.icns"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    echo "Error: $PLIST_TEMPLATE missing — can't render Info.plist" >&2
    exit 1
fi

echo "==> Building release binary"
swift build -c release

# `.build/release/Gifmator` is a stable symlink into whatever products dir
# SwiftPM is using this version. Cross-check with `swift build --show-bin-path`
# so a future SwiftPM reshuffle still produces a working bundle.
EXPECTED_BIN=".build/release/$BINARY_NAME"
BIN_DIR="$(swift build --show-bin-path -c release)"
RESOLVED_BIN="$BIN_DIR/$BINARY_NAME"

if [[ -x "$EXPECTED_BIN" ]]; then
    BINARY="$EXPECTED_BIN"
elif [[ -x "$RESOLVED_BIN" ]]; then
    BINARY="$RESOLVED_BIN"
else
    echo "Error: built binary not found at $EXPECTED_BIN or $RESOLVED_BIN" >&2
    exit 1
fi

echo "==> Cleaning stale $APP"
rm -rf "$APP"

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$BINARY_NAME"
chmod +x "$APP/Contents/MacOS/$BINARY_NAME"

echo "==> Rendering Info.plist (version $VERSION)"
sed "s/@VERSION@/$VERSION/g" "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
    echo "==> Bundled $ICON_SOURCE"
else
    echo "==> No $ICON_SOURCE found — bundle will show the default system icon"
fi

echo "==> Stripping com.apple.quarantine (so Gatekeeper doesn't block a locally built bundle)"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

SIZE="$(du -sh "$APP" | cut -f1)"
echo ""
echo "Built $REPO_ROOT/$APP ($SIZE)"
