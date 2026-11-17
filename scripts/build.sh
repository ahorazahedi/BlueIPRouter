#!/bin/sh
# Builds build/BlueIPRouter.app (release, ad-hoc signed).
#   sh scripts/build.sh            build only
#   sh scripts/build.sh --install  build and copy to ~/Applications
#   sh scripts/build.sh --zip      build and package build/BlueIPRouter-<version>.zip
#   UNIVERSAL=1 sh scripts/build.sh  Apple Silicon + Intel binary
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/BlueIPRouter.app"
# Override for your own fork: BUNDLE_ID=com.example.blueiprouter sh scripts/build.sh
BUNDLE_ID="${BUNDLE_ID:-com.blueiprouter.app}"
# Single source of truth for the version: BIR.version in Sources/BlueIPRouterCore/Models.swift
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/BlueIPRouterCore/Models.swift")
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# GitHub repository the app checks for updates (owner/name)
REPOSITORY="${REPOSITORY:-ahorazahedi/BlueIPRouter}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Apple Silicon + Intel in one app. Builds each architecture separately (works without full Xcode)
  # and merges them with lipo.
  echo "==> Compiling (release, arm64 + x86_64)"
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  ARM=$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)
  X86=$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)
  BIN="$ROOT/build/universal"
  rm -rf "$BIN" && mkdir -p "$BIN"
  for exe in BlueIPRouter blueiprouter-helper; do
    lipo -create "$ARM/$exe" "$X86/$exe" -output "$BIN/$exe"
  done
  lipo -info "$BIN/BlueIPRouter"
else
  echo "==> Compiling (release)"
  swift build -c release
  BIN=$(swift build -c release --show-bin-path)
fi

ICNS="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  echo "==> Rendering icon"
  rm -rf "$ROOT/build/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset"
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ICNS"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BlueIPRouter" "$APP/Contents/MacOS/BlueIPRouter"
cp "$BIN/blueiprouter-helper" "$APP/Contents/MacOS/blueiprouter-helper"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BlueIPRouter</string>
  <key>CFBundleDisplayName</key><string>BlueIPRouter</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>BlueIPRouter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>BlueIPRouterRepository</key><string>$REPOSITORY</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/blueiprouter-helper"
codesign --force --sign - "$APP"

if [ "$1" = "--zip" ] || [ "$2" = "--zip" ]; then
  (cd "$ROOT/build" && rm -f "BlueIPRouter-$VERSION.zip" && ditto -c -k --keepParent BlueIPRouter.app "BlueIPRouter-$VERSION.zip")
  echo "==> Packaged build/BlueIPRouter-$VERSION.zip"
fi

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/BlueIPRouter.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "==> Installed to $HOME/Applications/BlueIPRouter.app"
fi
echo "==> Done: $APP"
