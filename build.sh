#!/usr/bin/env bash
#
# Builds Update Scout.app from the Swift package.
#
#   ./build.sh            build into ./dist/Update Scout.app
#   ./build.sh --install  build, then copy it into /Applications and launch it
#   ./build.sh --universal --identity "Developer ID Application: …"
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Update Scout"
BUILD_PRODUCT_NAME="UpdateScout"
EXECUTABLE_NAME="Update Scout"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"
INSTALL=false
UNIVERSAL=false
SIGN_IDENTITY="-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=true; shift ;;
    --universal) UNIVERSAL=true; shift ;;
    --identity)
      [[ $# -ge 2 ]] || { echo "--identity needs a certificate name" >&2; exit 2; }
      SIGN_IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "==> Building release binary"
cd "$ROOT"
BUILD_ARGS=(-c release)
if [[ "$UNIVERSAL" == true ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"

# `tail -n 1` guards against SwiftPM occasionally putting resolution chatter
# on stdout ahead of the path.
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path 2>/dev/null | tail -n 1)/$BUILD_PRODUCT_NAME"
if [[ ! -x "$BINARY" ]]; then
  echo "Build produced no binary at $BINARY" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$DIST/UpdateScout.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Info.plist already names AppIcon; regenerate the .icns if it went missing.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]] && command -v python3 >/dev/null; then
  python3 "$ROOT/Resources/make_icon.py" || echo "(icon generation skipped — needs Pillow)"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT/Resources/sources.sample.json" ]]; then
  cp "$ROOT/Resources/sources.sample.json" "$BUNDLE/Contents/Resources/sources.sample.json"
fi

# Seed for ~/.config/updatescout/sources.json, copied out on first use.
if [[ -f "$ROOT/Resources/sources.sample.json" ]]; then
  cp "$ROOT/Resources/sources.sample.json" "$BUNDLE/Contents/Resources/sources.sample.json"
fi

echo "==> Signing"
# Finder metadata and resource-fork attributes invalidate a strict signature if
# the source tree or a previously launched bundle contributed them.
xattr -cr "$BUNDLE"
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
SIGNED=false
for _ in 1 2 3; do
  # File-provider folders can reattach Finder metadata immediately after it is
  # removed. Clear it directly before each signing attempt.
  xattr -cr "$BUNDLE"
  if codesign "${SIGN_ARGS[@]}" "$BUNDLE"; then
    SIGNED=true
    break
  fi
done
[[ "$SIGNED" == true ]] || { echo "Could not sign $BUNDLE" >&2; exit 1; }

echo "==> Built $BUNDLE"

if [[ "$INSTALL" == true ]]; then
  echo "==> Installing to /Applications"
  # Quit a running copy first, or the replace will fail.
  pkill -x "$BUILD_PRODUCT_NAME" 2>/dev/null || true
  pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
  sleep 1
  # Remove the former no-space bundle name when upgrading an existing install.
  rm -rf "/Applications/UpdateScout.app"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
  xattr -cr "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  # The installed copy is canonical. Do not leave a second launchable app in
  # dist for Spotlight and application launchers to index.
  rm -rf "$BUNDLE"
  echo "==> Running. Look for the icon in your menu bar."
else
  echo
  echo "Run it with:   open \"$BUNDLE\""
  echo "Install it:    ./build.sh --install"
fi
