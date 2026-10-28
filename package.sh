#!/usr/bin/env bash
#
# Builds the app and packages it into an installable disk image.
#
#   ./package.sh            # build + 工作日-<version>.dmg
#   ./package.sh --zip      # also produce a .zip
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="WorkdayWidget"
APP="$ROOT/$APP_NAME.app"
DIST="$ROOT/dist"
VOL_NAME="工作日"

WANT_ZIP=0
for arg in "$@"; do
  [[ "$arg" == "--zip" ]] && WANT_ZIP=1
done

echo "==> 构建应用"
"$ROOT/build.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
AUTHOR="$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$APP/Contents/Info.plist")"
DMG="$DIST/工作日-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

STAGE="$(mktemp -d)/$VOL_NAME"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<EOF
$VOL_NAME $VERSION
$AUTHOR

安装
1. 把「$APP_NAME.app」拖到旁边的 Applications 文件夹。
2. 打开「启动台」或「应用程序」，运行「工作日」。

首次打开被系统拦截时
本应用使用 ad-hoc 签名、未经过 Apple 公证，Gatekeeper 可能提示
“无法打开，因为无法验证开发者”。任选一种方式解决：

  A. 在「系统设置 → 隐私与安全性」里点「仍要打开」。
  B. 在终端执行：
     xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

使用
- 应用不占用 Dock 图标，只在菜单栏显示一个进度环和百分比。
- 桌面组件可直接拖动，位置会被记住。
- 把鼠标移到 MacBook 刘海上，灵动岛会向下展开当天的工作进度。
- 菜单栏图标 →「设置…」可修改上下班、午休、晚餐时间。

到点提醒
- 午休、晚餐、下班的时刻，灵动岛会自动展开提醒；上滑、点击或 3 秒后收起。
- 提醒的时间、标题、正文都能改，也可以关掉或新增自定义提醒。
- 菜单栏「测试提醒」可以立刻看效果。

工作时间统计
- 菜单栏图标 →「工作时间统计…」查看本周 / 本月 / 全部的实际工时。
- 下班时间取当天最后一次锁屏；这笔记录写在
  ~/Library/Application Support/Workday/worklog.json
- 记录需要应用一直在运行。系统不提供锁屏历史，应用没运行时
  发生的锁屏观测不到，那天会按排班下班时间结算（明细里标为「排班」）。
- 可在「设置 → 工时记录」里打开「登录时自动启动」。

要求：macOS 14 或更高版本。
EOF

echo "==> 生成磁盘映像"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

rm -rf "$(dirname "$STAGE")"

if [[ "$WANT_ZIP" == "1" ]]; then
  echo "==> 生成 zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/工作日-$VERSION.zip"
fi

echo
echo "==> 打包完成"
for f in "$DIST"/*; do
  printf '    %s  (%s)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo
echo "    校验: shasum -a 256 dist/*"
