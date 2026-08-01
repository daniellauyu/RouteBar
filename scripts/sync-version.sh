#!/bin/bash
# 把仓库根 VERSION 的版本号同步到所有版本声明处。
#
# 单一来源是 VERSION 文件；改版本时只改它，然后跑本脚本。
#
# 同步目标：
#   - RouteBar/RouteBarApp/AppVersion.swift 的 fallback
#   - RouteBar.xcodeproj 的 MARKETING_VERSION

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION_FILE="VERSION"
APP_VERSION_SWIFT="RouteBar/RouteBarApp/AppVersion.swift"
PBXPROJ="RouteBar.xcodeproj/project.pbxproj"

for file in "$VERSION_FILE" "$APP_VERSION_SWIFT" "$PBXPROJ"; do
    if [[ ! -f "$file" ]]; then
        echo "错误：找不到 $file" >&2
        exit 1
    fi
done

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：VERSION 不是合法的三段式版本号：'$VERSION'" >&2
    exit 1
fi

sed -i '' -E "s/static let fallback = \"[0-9]+\.[0-9]+\.[0-9]+\"/static let fallback = \"$VERSION\"/" "$APP_VERSION_SWIFT"
sed -i '' -E "s/MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"

# 复核：两处必须一致，否则打包出来的版本号会和仓库对不上。
FALLBACK="$(sed -n -E 's/.*static let fallback = "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$APP_VERSION_SWIFT")"
MARKETING="$(sed -n -E 's/.*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);.*/\1/p' "$PBXPROJ" | sort -u)"

if [[ "$FALLBACK" != "$VERSION" || "$MARKETING" != "$VERSION" ]]; then
    echo "错误：同步后版本不一致 —— VERSION=$VERSION fallback=$FALLBACK MARKETING_VERSION=$MARKETING" >&2
    exit 1
fi

echo "版本已同步到 $VERSION"
echo "  $APP_VERSION_SWIFT  fallback = $FALLBACK"
echo "  $PBXPROJ            MARKETING_VERSION = $MARKETING"
