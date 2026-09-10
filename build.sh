#!/bin/bash
# 打成一个能双击的 Smudge.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
VERSION="${VERSION:-0.1.1}"
APP="build/Smudge.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Smudge"
[ -x "$BIN" ] || { echo "没找到编译产物 $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Smudge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Smudge</string>
  <key>CFBundleDisplayName</key>       <string>Smudge</string>
  <key>CFBundleIdentifier</key>        <string>dev.smudge.overlay</string>
  <key>CFBundleExecutable</key>        <string>Smudge</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

/usr/bin/sed -i '' "s/__VERSION__/$VERSION/" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" 2>/dev/null || echo "（ad-hoc 签名跳过了，不影响运行）"

echo "==> 好了：$APP"
echo "    打开：open $APP"
echo "    退出：菜单栏那滴油 → 退出 Smudge"
