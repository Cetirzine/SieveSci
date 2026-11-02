#!/usr/bin/env bash
# Builds SieveSci.app from the SwiftPM products (app, CLI, resource bundle), zips it and makes a disk image in dist/.
# Usage: scripts/bundle-app.sh [debug|release] [--scratch-path DIR]   (default: release, .build)
# Environment:
#   SCRATCH       build directory (same as --scratch-path)
#   SDKROOT       SDK to build against; when unset the default SDK is used, falling back to FALLBACK_SDK
#                 if the default one can't build SwiftUI macros (Command Line Tools without Xcode)
#   FALLBACK_SDK  default: /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
#   ICON_SVG      app icon source; default: ../Sileve Design/ghost-logo/svg/ghost-aurora.svg, else the copy
#                 embedded in Sources/SieveSciApp/BrandSVG.swift
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
SCRATCH="${SCRATCH:-.build}"
while [ $# -gt 0 ]; do
  case "$1" in
    debug|release) CONFIG="$1" ;;
    --scratch-path) SCRATCH="${2:?--scratch-path needs a directory}"; shift ;;
    --scratch-path=*) SCRATCH="${1#*=}" ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

FALLBACK_SDK="${FALLBACK_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
# Command Line Tools ship no SwiftUIMacros plugin, which the newest SDK's SwiftUI needs (NetworkImage, a
# MarkdownUI dependency, fails with "plugin for module 'SwiftUIMacros' not found"). Pick the older SDK up front.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]] && [ -d "$FALLBACK_SDK" ]; then
  plugins="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins"
  if [ ! -e "$plugins/libSwiftUIMacros.dylib" ]; then
    echo "note: Command Line Tools without SwiftUIMacros; building against $FALLBACK_SDK"
    export SDKROOT="$FALLBACK_SDK"
  fi
fi

LOG="$(mktemp -t sievesci-build)"
trap 'rm -f "$LOG"' EXIT
build() {
  if swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product "$1" 2>&1 | tee "$LOG"; then return 0; fi
  # Safety net if the up-front check missed: retry once against the fallback SDK.
  if [ -z "${SDKROOT:-}" ] && [ -d "$FALLBACK_SDK" ] && grep -q "SwiftUIMacros" "$LOG"; then
    echo "note: default SDK can't build SwiftUI macros; retrying against $FALLBACK_SDK"
    export SDKROOT="$FALLBACK_SDK"
    swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product "$1"
  else
    return 1
  fi
}

APP="dist/SieveSci.app"
rm -rf "$APP" dist/SieveSci.app.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# On a case-insensitive disk the products `SieveSci` (app) and `sievesci` (CLI) are the same file in the bin
# dir, so each binary is copied out right after it is built (and the stale one removed so it always relinks).
# The CLI goes in as `sievesci-cli`: `sievesci` would collide with the app executable in Contents/MacOS too.
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"
rm -f "$BIN/SieveSci"
build SieveSci
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"
cp "$BIN/SieveSci" "$APP/Contents/MacOS/SieveSci"
if ! otool -L "$APP/Contents/MacOS/SieveSci" | grep -q SwiftUI.framework; then
  echo "error: $BIN/SieveSci is not the SwiftUI app (does not link SwiftUI)" >&2; exit 1
fi
rm -f "$BIN/sievesci"
build sievesci
cp "$BIN/sievesci" "$APP/Contents/MacOS/sievesci-cli"

# Resource bundles go in Contents/Resources (SieveSciResources looks there; the bundle root must stay clean for signing).
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Localizations at the app level too, so AppKit's own UI (menus, panels) follows the language.
for l in en zh-Hans zh-Hant ru es fr; do mkdir -p "$APP/Contents/Resources/$l.lproj"; done

# App icon (Finder, Launchpad): the aurora ghost on a transparent background, inset like the runtime dock icon.
ICON_DIR="$SCRATCH/app-icon"
ICON_SVG="${ICON_SVG:-../Sileve Design/ghost-logo/svg/ghost-aurora.svg}"
mkdir -p "$ICON_DIR"
if [ ! -f "$ICON_SVG" ]; then
  ICON_SVG="$ICON_DIR/ghost-aurora.svg"
  awk '/static let aurora = #"""/{on=1; next} on && /^"""#/{exit} on' Sources/SieveSciApp/BrandSVG.swift > "$ICON_SVG"
fi
ICON_FILE=""
if [ -s "$ICON_SVG" ]; then
  if [ ! -f "$ICON_DIR/AppIcon.icns" ] || [ "$ICON_SVG" -nt "$ICON_DIR/AppIcon.icns" ]; then
    cat > "$ICON_DIR/render-icon.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: render-icon <svg> <iconset dir>\n".data(using: .utf8)!); exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        let side = CGFloat(px)
        svg.draw(in: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.06))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
SWIFT
    rm -rf "$ICON_DIR/AppIcon.iconset"
    if swiftc -O -o "$ICON_DIR/render-icon" "$ICON_DIR/render-icon.swift" \
      && "$ICON_DIR/render-icon" "$ICON_SVG" "$ICON_DIR/AppIcon.iconset" \
      && iconutil -c icns -o "$ICON_DIR/AppIcon.icns" "$ICON_DIR/AppIcon.iconset"; then :; else
      rm -f "$ICON_DIR/AppIcon.icns"; echo "warning: could not render the app icon"
    fi
  fi
  if [ -f "$ICON_DIR/AppIcon.icns" ]; then cp "$ICON_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; ICON_FILE=AppIcon; fi
else
  echo "warning: no icon SVG found; the bundle has no app icon"
fi
ICON_PLIST=""
[ -n "$ICON_FILE" ] && ICON_PLIST="<key>CFBundleIconFile</key><string>${ICON_FILE}</string>"

VERSION="$(grep -Eo 'version = "[^"]+"' Sources/SieveSciCore/Version.swift 2>/dev/null | head -1 | cut -d'"' -f2)"
VERSION="${VERSION:-0.1.0}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SieveSci</string>
  <key>CFBundleDisplayName</key><string>SieveSci</string>
  <key>CFBundleIdentifier</key><string>app.sievesci.SieveSci</string>
  <key>CFBundleExecutable</key><string>SieveSci</string>
  ${ICON_PLIST}
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ru</string><string>es</string><string>fr</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Keychain and notifications work locally (not notarized).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; the app still runs locally"
# Re-register so Finder picks up the (possibly changed) icon instead of a cached one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
(cd dist && ditto -c -k --keepParent SieveSci.app SieveSci.app.zip)

# Disk image: the app next to an Applications link, to drag across. The in-app updater installs from it too.
DMG="dist/SieveSci-$VERSION.dmg"
DMG_STAGE="$(mktemp -d -t sievesci-dmg)"
ditto "$APP" "$DMG_STAGE/SieveSci.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "SieveSci $VERSION" -srcfolder "$DMG_STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$DMG_STAGE"
echo "Built dist/SieveSci.app ($VERSION), dist/SieveSci.app.zip and $DMG"
