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

# 公开分发的包一律改成 ad-hoc 签名。
#
# Xcode 默认用你的 Apple Development 证书签名，而证书里带着开发者的 Apple ID 邮箱——
# 拿到包的任何人跑一次 `codesign -dvvv` 就能看到，开源发布时这是白送出去的个人信息。
# 证书还会过期。ad-hoc（-s -）不含任何身份，也不会过期。
#
# 用户体验没有区别：两种都没有经过 Apple 公证，下载后都要放行一次
# （xattr -dr com.apple.quarantine，或在「隐私与安全性」里点「仍要打开」）。
#
# --options runtime 保留 hardened runtime；bundle 里没有嵌套的框架或插件，
# 所以不需要（已被 Apple 建议弃用的）--deep。
echo "ad-hoc 签名…"
codesign --force --sign - --options runtime --timestamp=none "$APP"

# 签名结果必须真的是 adhoc：万一哪天签错了，个人身份会跟着包发出去，
# 而这种事发出去就收不回来了，所以在打包前挡住而不是事后发现。
SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"
if ! grep -q '^Signature=adhoc' <<< "$SIGN_INFO"; then
    echo "错误：签名不是 ad-hoc，包里可能带有开发者身份：" >&2
    grep -E '^(Authority|TeamIdentifier|Signature)' <<< "$SIGN_INFO" | sed 's/^/  /' >&2
    exit 1
fi
codesign --verify --strict "$APP"

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "已打包 $ZIP"
echo "  版本  ${BUNDLE_VERSION}"
echo "  最低系统  $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "  提交  $(git rev-parse --short HEAD)"
echo "  签名  ad-hoc（未公证，用户首次打开需放行）"
