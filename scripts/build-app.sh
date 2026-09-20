#!/bin/bash
# 构建 IdeaLightRun.app（debug 或 release），供本机双击使用。
# 用法: ./scripts/build-app.sh [release]
#   UNIVERSAL=1  产 arm64 + x86_64 通用包（发布用，仅 release）
#   APP_VERSION  写入 CFBundleVersion/ShortVersionString，默认 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="${APP_VERSION:-0.1.0}"
BUILD_UNIVERSAL=0
if [ "${UNIVERSAL:-}" = "1" ] && [ "$CONFIG" = "release" ]; then
    BUILD_UNIVERSAL=1
    swift build -c release --arch arm64 --arch x86_64
else
    swift build -c "$CONFIG"
fi

APP="build/IdeaLightRun.app"
# 通用构建产物落在 .build/apple/Products，与单架构路径不同；按本次配置精确取，
# 否则可能打包到上一次另一配置的旧二进制。
if [ "$BUILD_UNIVERSAL" = "1" ]; then
    BINARY=".build/apple/Products/Release/IdeaLightRunApp"
else
    BINARY=".build/$CONFIG/IdeaLightRunApp"
fi
[ -f "$BINARY" ] || { echo "❌ 找不到 $BINARY" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/IdeaLightRun"

# 应用图标（icns 缺失时从源图重新生成）
if [ ! -f scripts/AppIcon.icns ]; then
    swift scripts/make-icon.swift scripts/AppIconSource.png scripts/AppIcon.icns
fi
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>IdeaLightRun</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.idealightrun.app</string>
    <key>CFBundleName</key>
    <string>IdeaLightRun</string>
    <key>CFBundleDisplayName</key>
    <string>IdeaLightRun</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "✅ Built $APP (v${VERSION}, $(lipo -archs "$APP/Contents/MacOS/IdeaLightRun"))"
