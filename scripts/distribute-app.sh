#!/bin/bash
# 出正式包：Developer ID 签名 → 公证 → staple → 重新打包 → 校验，产物在 dist/。
# 公证凭据二选一：
#   IDEALIGHTRUN_APPLE_API_KEY_PATH + _APPLE_API_KEY_ID + _APPLE_API_ISSUER（CI 走这条）
#   IDEALIGHTRUN_NOTARY_PROFILE（本机 notarytool 凭据档，默认 idealightrun-notary）
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/IdeaLightRun.app"
DIST="dist"
PROFILE="${IDEALIGHTRUN_NOTARY_PROFILE:-idealightrun-notary}"
API_KEY_READY=0
if [ -n "${IDEALIGHTRUN_APPLE_API_KEY_PATH:-}" ] && [ -n "${IDEALIGHTRUN_APPLE_API_KEY_ID:-}" ] \
    && [ -n "${IDEALIGHTRUN_APPLE_API_ISSUER:-}" ]; then
    API_KEY_READY=1
fi

IDEALIGHTRUN_UNIVERSAL=1 ./scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$DIST/IdeaLightRun-${VERSION}-universal.zip"
mkdir -p "$DIST"

echo "==> 打包已签名产物"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> 提交 Apple 公证"
if [ "$API_KEY_READY" = "1" ]; then
    xcrun notarytool submit "$ZIP" \
        --key "$IDEALIGHTRUN_APPLE_API_KEY_PATH" \
        --key-id "$IDEALIGHTRUN_APPLE_API_KEY_ID" \
        --issuer "$IDEALIGHTRUN_APPLE_API_ISSUER" \
        --wait
else
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
fi

echo "==> staple 公证票据"
# 未被 Accept 时 staple 会失败，正式包不可能带着未公证的产物往下走。
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> 重新打包 stapled 产物"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> 校验最终产物"
codesign --verify --deep --strict "$APP"
# 更新助手必须独立可验：在线更新靠它替换 bundle，缺了它的包会把用户
# 留在「只能手动升级」的版本上，而这一点要在这里拦住，不能等用户点「下载并安装」。
[ -x "$APP/Contents/MacOS/IdeaLightRunUpdater" ] \
    || { echo "❌ 正式包缺更新助手 IdeaLightRunUpdater" >&2; exit 1; }
codesign --verify --strict "$APP/Contents/MacOS/IdeaLightRunUpdater"
spctl --assess --type execute --verbose "$APP"
for arch in arm64 x86_64; do
    lipo -archs "$APP/Contents/MacOS/IdeaLightRun" | grep -qw "$arch" \
        || { echo "❌ 产物缺 $arch 切片" >&2; exit 1; }
done
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt && cat SHA256SUMS.txt)

echo "✅ 正式包: $PWD/$ZIP"
