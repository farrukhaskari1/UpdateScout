#!/usr/bin/env bash
#
# Builds UpdateScout.app from the Swift package.
#
#   ./build.sh            build into ./dist/UpdateScout.app
#   ./build.sh --install  build, then move it into /Applications and launch it
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="UpdateScout"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release --disable-sandbox

# `tail -n 1` guards against SwiftPM occasionally putting resolution chatter
# on stdout ahead of the path.
BINARY="$(swift build -c release --show-bin-path 2>/dev/null | tail -n 1)/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
  echo "Build produced no binary at $BINARY" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Info.plist already names AppIcon; regenerate the .icns if it went missing.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]] && command -v python3 >/dev/null; then
  python3 "$ROOT/Resources/make_icon.py" || echo "(icon generation skipped — needs Pillow)"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Seed for ~/.config/updatescout/sources.json, copied out on first use.
if [[ -f "$ROOT/Resources/sources.sample.json" ]]; then
  cp "$ROOT/Resources/sources.sample.json" "$BUNDLE/Contents/Resources/sources.sample.json"
fi

echo "==> Signing (ad-hoc)"
# Ad-hoc signature is enough to run locally and to register a login item.
codesign --force --deep --sign - "$BUNDLE"

echo "==> Built $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  # Quit a running copy first, or the replace will fail.
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Running. Look for the icon in your menu bar."
else
  echo
  echo "Run it with:   open \"$BUNDLE\""
  echo "Install it:    ./build.sh --install"
fi
