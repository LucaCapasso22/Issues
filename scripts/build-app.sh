#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
SCRATCH_DIR="${ISSUES_BUILD_DIR:-/private/tmp/issues-swift-build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/issues-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/issues-swift-cache}"
swift build -c release --scratch-path "$SCRATCH_DIR" --cache-path /private/tmp/issues-spm-cache --disable-sandbox
BINARY_DIR="$(swift build -c release --scratch-path "$SCRATCH_DIR" --cache-path /private/tmp/issues-spm-cache --disable-sandbox --show-bin-path)"
APP_DIR="$PROJECT_DIR/release/Issues.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/Issues" "$APP_DIR/Contents/MacOS/Issues"
# A packaged macOS app resolves SwiftPM resources inside Contents/Resources.
ditto "$BINARY_DIR/Issues_IssuesDesktop.bundle" "$APP_DIR/Contents/Resources/Issues_IssuesDesktop.bundle"
if [ -d "$APP_DIR/Contents/MacOS/Issues_IssuesDesktop.bundle" ]; then
  rm -r "$APP_DIR/Contents/MacOS/Issues_IssuesDesktop.bundle"
fi
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.issues.desktop</string>
<key>CFBundleName</key><string>Issues</string>
<key>CFBundleDisplayName</key><string>Issues</string>
<key>CFBundleExecutable</key><string>Issues</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [ -f "$PROJECT_DIR/resources/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# Remove exFAT AppleDouble metadata from the assembled bundle only.
find "$APP_DIR" -name '._*' -type f -delete
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
