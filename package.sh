#!/bin/bash
# 打一个可以拖进 Applications 的 DMG
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.1.1}"
APP="build/Smudge.app"
STAGE="build/dmg"
DMG="build/Smudge-$VERSION.dmg"

VERSION="$VERSION" ./build.sh release >/dev/null

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 装完第一次打开会被 Gatekeeper 拦（ad-hoc 签名），把办法放进包里
cat > "$STAGE/先读我.txt" <<'TXT'
Smudge —— Agent 干活的时候屏幕会变脏，拖窗口就是擦。

装：把 Smudge 拖到旁边的 Applications。

第一次打开会被拦下来说「无法打开，因为无法验证开发者」。
这是因为这个包只做了 ad-hoc 签名，没有花钱买苹果的开发者证书。
绕过办法二选一：

  1) 在 Applications 里右键点 Smudge → 打开 → 再点一次「打开」
  2) 终端里跑：xattr -dr com.apple.quarantine /Applications/Smudge.app

装好之后菜单栏会出现一滴油。先点「喷一把脏（试手感）」，
然后拖任何一个窗口试试擦。退出也在那个菜单里。

不需要任何系统权限：不读屏幕内容，所以不用录屏权限；
窗口位置走公开接口，所以不用辅助功能权限。
TXT

hdiutil create -volname "Smudge $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo "==> $DMG  ($(du -h "$DMG" | cut -f1))"
