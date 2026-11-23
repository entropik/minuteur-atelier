#!/bin/bash
# Compile le panneau flottant « Minuteur atelier » en binaire universel (Apple Silicon + Intel),
# intègre l'icône AppIcon.icns et l'installe dans ~/Applications.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Minuteur Atelier.app"
build="$here/.build"

mkdir -p "$build"

# 1. Compiler pour Apple Silicon (arm64) et Intel (x86_64) puis fusionner avec lipo
swiftc -O "$here/main.swift" -o "$build/MinuteurAtelier-arm64" \
  -framework AppKit \
  -framework UserNotifications \
  -target arm64-apple-macosx14.0

swiftc -O "$here/main.swift" -o "$build/MinuteurAtelier-x86_64" \
  -framework AppKit \
  -framework UserNotifications \
  -target x86_64-apple-macosx14.0

lipo -create \
  "$build/MinuteurAtelier-arm64" \
  "$build/MinuteurAtelier-x86_64" \
  -output "$build/MinuteurAtelier"

# 2. Installer le bundle .app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/MinuteurAtelier" "$app/Contents/MacOS/MinuteurAtelier"

if [ -f "$here/AppIcon.icns" ]; then
  cp "$here/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Minuteur Atelier</string>
  <key>CFBundleDisplayName</key><string>Minuteur Atelier</string>
  <key>CFBundleIdentifier</key><string>com.ooblik.minuteur-atelier</string>
  <key>CFBundleExecutable</key><string>MinuteurAtelier</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 ooblik. Sous licence GNU GPLv3.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app" >/dev/null 2>&1
rm -rf "$build"

echo "Construit (Universal Binary arm64 + x86_64) : $app"
