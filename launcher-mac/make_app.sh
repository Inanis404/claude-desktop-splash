#!/bin/bash
# Creates the splash app for macOS (counterpart of launcher/make_shortcut.ps1).
#   --name NAME      name of the app (default: "Claude (splash)")
#   --applications   create it in ~/Applications instead of this folder
#   --art ART        new (default) | classic  -- which artwork the app plays
#   --no-sound       no startup sound
# The app is written into this folder (or ~/Applications) and remembers where the repository
# is: do not move the repository afterwards (run this script again if you do).
# Needs the Xcode Command Line Tools (xcode-select --install) for swiftc.
set -euo pipefail

name="Claude (splash)"
applications=0
art="new"
sound=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --applications) applications=1; shift ;;
    --art) art="$2"; shift 2 ;;
    --no-sound) sound=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$art" in new|classic) ;; *) echo "--art must be new or classic" >&2; exit 2 ;; esac
command -v swiftc >/dev/null || { echo "swiftc not found: run xcode-select --install first" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
if [ "$applications" = 1 ]; then dest="$HOME/Applications"; mkdir -p "$dest"; else dest="$here"; fi
app="$dest/$name.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
echo "compiling..."
swiftc -O "$here/ClaudeSplash.swift" -o "$app/Contents/MacOS/ClaudeSplash" -framework Cocoa -framework WebKit

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.claude-desktop-splash</string>
  <key>CFBundleExecutable</key><string>ClaudeSplash</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# values that may contain any characters go in through plutil (it escapes them)
plist="$app/Contents/Info.plist"
plutil -insert CFBundleName -string "$name" "$plist"
plutil -insert SplashRepo -string "$repo" "$plist"
plutil -insert SplashArt -string "$art" "$plist"
plutil -insert SplashNoSound -bool "$([ "$sound" = 0 ] && echo YES || echo NO)" "$plist"

# Icon from the project's own assets/icon.png (never Claude's icon)
tmp="$(mktemp -d)"
mkdir "$tmp/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$repo/assets/icon.png" --out "$tmp/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1 || true
done
iconutil -c icns "$tmp/icon.iconset" -o "$app/Contents/Resources/icon.icns" 2>/dev/null || true
rm -rf "$tmp"

codesign --force --sign - "$app" 2>/dev/null || true   # local ad-hoc signature

echo "created: $app"
