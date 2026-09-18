#!/bin/bash
# 构建 IdeaLightRun.app（debug 或 release），供本机双击使用。
# 用法: ./scripts/build-app.sh [release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/IdeaLightRun.app"
BINARY="$(ls .build/*/IdeaLightRunApp 2>/dev/null | head -1)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/IdeaLightRun"

# 应用图标（icns 缺失时从源图重新生成）
if [ ! -f scripts/AppIcon.icns ]; then
    swift scripts/make-icon.swift scripts/AppIconSource.png scripts/AppIcon.icns
fi
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
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
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
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
echo "✅ Built $APP"
