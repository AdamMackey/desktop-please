#!/bin/bash
# Builds Desktop Please.
#   ./build.sh             build, install to /Applications and open it
#   ./build.sh bundle      only build "build/Desktop Please.app" (release.sh uses this)
#   ./build.sh uninstall   quit it, remove its login item and delete it
#
# Needs Xcode or the Command Line Tools, for swiftc.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Desktop Please"                   # what shows in Finder, Login Items and Accessibility
EXE="DesktopPlease"                     # executable and source file name
BUNDLE_ID="com.adammackey.desktopplease"
VERSION="1.0"
BUNDLE="build/$NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# /Applications is group-writable by admin accounts, so this needs no sudo.
# Falls back to the per-user folder if the account can't write there.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

build_bundle() {
  rm -rf build
  mkdir -p "$BUNDLE/Contents/MacOS"
  swiftc -O -framework AppKit -framework Carbon -framework ServiceManagement \
    -o "$BUNDLE/Contents/MacOS/$EXE" "$EXE.swift"
  cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$EXE</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<!-- No Dock icon, no menu bar icon, no window. -->
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}

# Asks a running copy to quit (SIGTERM), so it hands the system shortcuts back
# before exiting, and waits for it to go.
quit_running() {
  pkill -TERM -x "$EXE" 2>/dev/null || return 0
  for _ in {1..10}; do
    pgrep -x "$EXE" >/dev/null || return 0
    sleep 0.3
  done
  echo "$NAME didn't quit, force-quitting it." >&2
  pkill -KILL -x "$EXE" 2>/dev/null || true
}

case "${1:-install}" in
  bundle)
    build_bundle
    ;;
  install)
    build_bundle
    # Sign with a fixed identity when there is one, so the Accessibility
    # permission survives rebuilds: macOS ties it to the signing identity, and
    # an ad-hoc signature is a brand new identity every build.
    IDENTITY="Apple Development"
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
      codesign --force --sign "$IDENTITY" "$BUNDLE" >/dev/null
    else
      echo "No '$IDENTITY' identity, signing ad-hoc: Accessibility must be allowed again after each rebuild." >&2
      codesign --force --sign - "$BUNDLE" >/dev/null
    fi
    quit_running
    rm -rf "$DEST/$NAME.app"
    ditto "$BUNDLE" "$DEST/$NAME.app"
    # LaunchServices indexes the copy in build/ too, and Spotlight will happily
    # open that stale one. Unregister and delete it, then register the installed copy.
    "$LSREGISTER" -u "$BUNDLE" 2>/dev/null || true
    rm -rf build
    "$LSREGISTER" -f "$DEST/$NAME.app"
    # Opening it adds it to Login Items (first time only) and asks for Accessibility.
    open "$DEST/$NAME.app"
    echo "Installed and opened $DEST/$NAME.app."
    ;;
  uninstall)
    quit_running
    if [[ -x "$DEST/$NAME.app/Contents/MacOS/$EXE" ]]; then
      "$DEST/$NAME.app/Contents/MacOS/$EXE" --unregister
    fi
    "$LSREGISTER" -u "$DEST/$NAME.app" 2>/dev/null || true
    rm -rf "$DEST/$NAME.app"
    echo "Removed $NAME. Show Desktop is back to macOS's own."
    ;;
  *)
    echo "usage: ./build.sh [install | bundle | uninstall]" >&2
    exit 64
    ;;
esac
