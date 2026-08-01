#!/bin/bash
# 打 Release 包：构建 → 核对版本 → 压缩到 dist/RouteBar-<版本>.zip
#
# 版本号来自仓库根 VERSION（改版本请先改它再跑 scripts/sync-version.sh）。
#
# 注意：必须用 ditto 而不是 zip。zip 会破坏 .app bundle 里的符号链接与扩展属性，
# 解包后代码签名会失效。

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
ZIP="dist/RouteBar-${VERSION}.zip"

# 变量一律用 ${} 包起来：紧跟全角标点时，bash 会把全角字符当成变量名的一部分。
echo "构建 Release（版本 ${VERSION}）…"
xcodebuild -project RouteBar.xcodeproj -scheme RouteBar -configuration Release build > /dev/null

BUILD_DIR="$(xcodebuild -project RouteBar.xcodeproj -scheme RouteBar -configuration Release \
    -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')"
APP="${BUILD_DIR}/RouteBar.app"

if [[ ! -d "$APP" ]]; then
    echo "错误：找不到构建产物 $APP" >&2
    exit 1
fi

# 核对 bundle 里的版本，避免 VERSION 改了但没跑 sync-version.sh 就打出版本号对不上的包。
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "错误：产物版本 ${BUNDLE_VERSION} 与 VERSION(${VERSION}) 不一致，请先跑 scripts/sync-version.sh" >&2
    exit 1
fi

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "已打包 $ZIP"
echo "  版本  ${BUNDLE_VERSION}"
echo "  提交  $(git rev-parse --short HEAD)"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier)' | sed 's/^/  /' || true
