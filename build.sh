#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/signal-sift.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Signal Sift.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Signal Sift</string>
<key>CFBundleDisplayName</key><string>Signal Sift</string>
<key>CFBundleIdentifier</key><string>io.github.muddgrrrl.signal-sift</string>
<key>CFBundleExecutable</key><string>SignalSift</string>
<key>CFBundleIconFile</key><string>SignalSift.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

swift Icon.swift "$stage/icon.png"
mkdir "$stage/SignalSift.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$stage/SignalSift.iconset/icon_${size}x${size}.png" >/dev/null
    hi=$((size * 2))
    sips -z "$hi" "$hi" "$stage/icon.png" --out "$stage/SignalSift.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/SignalSift.iconset" -o "$app/Contents/Resources/SignalSift.icns"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -O -target "$arch-apple-macos13.0" SignalSift.swift -o "$stage/$arch"
done
lipo -create "$stage/arm64" "$stage/x86_64" -output "$app/Contents/MacOS/SignalSift"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/SignalSift" --self-test
ditto -c -k --keepParent "$app" "$stage/SignalSift-macOS.zip"
mv -f "$stage/SignalSift-macOS.zip" dist/
