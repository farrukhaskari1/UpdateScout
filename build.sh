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
# Assemble and sign in a scratch directory, never in the project tree.
#
# This repo can live under ~/Documents, ~/Desktop, or any other folder managed
# by iCloud Drive or another file provider. Those reattach com.apple.FinderInfo
# the moment it is cleared, so `xattr -cr` immediately before `codesign` still
# loses the race and `codesign --verify --strict` then reports "resource fork,
# Finder information, or similar detritus not allowed". TMPDIR is never synced,
# so the bundle is signed and verified somewhere nothing else touches it, and
# only the finished result is copied out.
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/updatescout-build.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/$APP_NAME.app"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Info.plist already names AppIcon; regenerate the .icns if it went missing.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]] && command -v python3 >/dev/null; then
  python3 "$ROOT/Resources/make_icon.py" || echo "(icon generation skipped — needs Pillow)"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
fi
# Seed for ~/.config/updatescout/sources.json, copied out on first use.
if [[ -f "$ROOT/Resources/sources.sample.json" ]]; then
  cp "$ROOT/Resources/sources.sample.json" "$STAGE/Contents/Resources/sources.sample.json"
fi

echo "==> Signing"
# The copies above can still carry attributes from the source tree.
xattr -cr "$STAGE"
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$STAGE" \
  || { echo "Could not sign the app bundle" >&2; exit 1; }

codesign --verify --strict "$STAGE" \
  || { echo "Signature did not verify" >&2; exit 1; }

if [[ "$INSTALL" == true ]]; then
  echo "==> Installing to /Applications"
  # Quit a running copy first, or the replace will fail.
  #
  # Ask politely before killing: a SIGTERM can land before UserDefaults has
  # flushed, silently discarding recent settings changes. `quit` lets the app
  # run applicationWillTerminate and write them out.
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || break
    sleep 0.4
  done
  # Fall back to a kill only if it is still up.
  pkill -x "$BUILD_PRODUCT_NAME" 2>/dev/null || true
  pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
  sleep 1
  # Remove the former no-space bundle name when upgrading an existing install.
  rm -rf "/Applications/UpdateScout.app"
  rm -rf "/Applications/$APP_NAME.app"
  # `ditto` preserves the signature, unlike `cp -R` followed by an xattr strip.
  # /Applications is not file-provider managed, so the strict check holds here.
  ditto "$STAGE" "/Applications/$APP_NAME.app"
  codesign --verify --strict "/Applications/$APP_NAME.app" \
    || { echo "Installed copy failed signature verification" >&2; exit 1; }
  open "/Applications/$APP_NAME.app"
  # The installed copy is canonical. Do not leave a second launchable app in
  # dist for Spotlight and application launchers to index.
  rm -rf "$DIST/UpdateScout.app" "$BUNDLE"
  echo "==> Installed and running. Look for the icon in your menu bar."
else
  mkdir -p "$DIST"
  rm -rf "$DIST/UpdateScout.app" "$BUNDLE"
  ditto "$STAGE" "$BUNDLE"
  echo "==> Built $BUNDLE"
  echo
  echo "Run it with:   open \"$BUNDLE\""
  echo "Install it:    ./build.sh --install"
  echo
  echo "Note: dist/ sits in the project tree. If that folder is synced by iCloud"
  echo "or another file provider, this copy may pick up Finder metadata that"
  echo "trips 'codesign --verify --strict'. The signature itself is valid —"
  echo "it was verified before copying. Use --install for a clean bundle."
fi
