#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="WorkdayWidget"
APP="$ROOT/$APP_NAME.app"
ICNS="$ROOT/Resources/AppIcon.icns"

# The machine may have Command Line Tools selected while a full Xcode is
# installed. Prefer a working Xcode toolchain (the CLT SDK can be newer than
# its bundled Swift compiler, which breaks Swift builds).
if [[ -z "${DEVELOPER_DIR:-}" || ! -x "${DEVELOPER_DIR}/usr/bin/xcrun" ]]; then
  for candidate in \
    "/Applications/Xcode-26.3.0.app/Contents/Developer" \
    "/Applications/Xcode.app/Contents/Developer"; do
    if [[ -d "$candidate" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "error: 找不到 swiftc。请安装 Xcode 或匹配的 Swift 工具链。" >&2
  exit 1
fi

if ! xcrun swiftc --version >/dev/null 2>&1; then
  echo "error: 当前 Swift 工具链不可用，请安装完整 Xcode 后重试。" >&2
  exit 1
fi

SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
ARCH="$(uname -m)"
SDK_VERSION="$(xcrun --show-sdk-version)"

WANT_ICON=0
WANT_PREVIEW=0
for arg in "$@"; do
  case "$arg" in
    --icon) WANT_ICON=1 ;;
    --preview) WANT_PREVIEW=1 ;;
  esac
done

echo "==> 编译 $APP_NAME ($ARCH, SDK $SDK_VERSION)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

"$SWIFTC" \
  -swift-version 5 \
  -O \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$ROOT"/Sources/*.swift

# The icon is rendered by the app itself, so it needs the binary to exist first.
if [[ ! -f "$ICNS" || "$WANT_ICON" == "1" ]]; then
  echo "==> 生成应用图标"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  MASTER="$(mktemp -d)/icon-1024.png"
  mkdir -p "$ICONSET"

  "$APP/Contents/MacOS/$APP_NAME" --render-icon "$MASTER" >/dev/null

  for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
              "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
              "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
  done

  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$(dirname "$ICONSET")" "$(dirname "$MASTER")"
fi

cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "==> 构建完成: $APP"

if [[ "$WANT_PREVIEW" == "1" ]]; then
  mkdir -p "$ROOT/preview"
  "$APP/Contents/MacOS/$APP_NAME" --render "$ROOT/preview/widget.png"
  "$APP/Contents/MacOS/$APP_NAME" --render "$ROOT/preview/island.png" --island
  "$APP/Contents/MacOS/$APP_NAME" --render-stats "$ROOT/preview/stats.png"
  "$APP/Contents/MacOS/$APP_NAME" --render "$ROOT/preview/reminder.png" --at 12:00 --island --reminder lunch
  echo "==> 预览图已生成: $ROOT/preview/"
fi
