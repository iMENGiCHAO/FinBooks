#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="FinBooks"
ARCHIVE_DIR="$PROJECT_DIR/archive"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
NATIVE_ARCH="$(uname -m)"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$PROJECT_DIR/Sources" -name "*.swift" -type f | sort)

echo "=== FinBooks 构建脚本 ==="
echo "本机架构: $NATIVE_ARCH"
echo ""

# Clean
rm -rf "$ARCHIVE_DIR" "$PROJECT_DIR/$APP_NAME"

# Step 1: compile for native arch
echo "=== 编译 ($NATIVE_ARCH) ==="
swiftc \
  -target "${NATIVE_ARCH}-apple-macosx15.0" \
  -sdk "$SDK_PATH" \
  -o "$PROJECT_DIR/$APP_NAME" \
  "${SOURCES[@]}" -O -module-cache-path /tmp/swiftmodcache 2>&1

file "$PROJECT_DIR/$APP_NAME"
echo "编译完成"

# Step 2: try arm64 cross-compile if on x86_64
if [ "$NATIVE_ARCH" = "x86_64" ]; then
    echo ""
    echo "=== 尝试编译 arm64 (Apple Silicon) ==="
    if swiftc \
      -target "arm64-apple-macosx15.0" \
      -sdk "$SDK_PATH" \
      -o "$PROJECT_DIR/${APP_NAME}-arm64" \
      "${SOURCES[@]}" -O -module-cache-path /tmp/swiftmodcache 2>&1; then
        echo "arm64 编译成功!"
        echo "=== 创建 Universal Binary ==="
        lipo -create \
          "$PROJECT_DIR/$APP_NAME" \
          "$PROJECT_DIR/${APP_NAME}-arm64" \
          -output "$PROJECT_DIR/${APP_NAME}-universal"
        mv "$PROJECT_DIR/${APP_NAME}-universal" "$PROJECT_DIR/$APP_NAME"
        rm -f "$PROJECT_DIR/${APP_NAME}-arm64"
        echo "Universal Binary 创建完成!"
    else
        echo "arm64 交叉编译不可用 (需要 Apple Silicon Mac 或完整 Xcode)"
        echo "将仅生成 $NATIVE_ARCH 版本"
    fi
fi

# Step 3: package as .app
echo ""
echo "=== 打包 .app ==="
APP_BUNDLE="$ARCHIVE_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon if exists
ICON_SRC="$PROJECT_DIR/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "已添加 AppIcon.icns"
fi

# Embed bridge script and agent plugins (for self-contained .app bundle, always runs)
echo "嵌入 Bridge 服务脚本..."
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
cp "$PROJECT_DIR/scripts/finbooks_bridge.py" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$PROJECT_DIR/scripts/install_finbooks_plugin.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
echo "嵌入插件文件..."

# Codex 插件
mkdir -p "$APP_BUNDLE/Contents/Resources/.codex-plugin"
cp "$PROJECT_DIR/.codex-plugin/plugin.json" "$APP_BUNDLE/Contents/Resources/.codex-plugin/"
cp "$PROJECT_DIR/.codex-plugin/SKILL.md" "$APP_BUNDLE/Contents/Resources/.codex-plugin/"

# Hermes 插件
mkdir -p "$APP_BUNDLE/Contents/Resources/.hermes-plugin"
cp "$PROJECT_DIR/.hermes-plugin/plugin.yaml" "$APP_BUNDLE/Contents/Resources/.hermes-plugin/"
cp "$PROJECT_DIR/.hermes-plugin/__init__.py" "$APP_BUNDLE/Contents/Resources/.hermes-plugin/"

# OpenClaw 插件
mkdir -p "$APP_BUNDLE/Contents/Resources/.openclaw-plugin"
cp "$PROJECT_DIR/.openclaw-plugin/plugin.yaml" "$APP_BUNDLE/Contents/Resources/.openclaw-plugin/"
cp "$PROJECT_DIR/.openclaw-plugin/__init__.py" "$APP_BUNDLE/Contents/Resources/.openclaw-plugin/"

echo "Bridge 和插件已嵌入 .app 包"



cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>FinBooks</string>
    <key>CFBundleExecutable</key>
    <string>FinBooks</string>
    <key>CFBundleIdentifier</key>
    <string>com.finbooks.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FinBooks</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 FinBooks. All rights reserved.</string>
</dict>
</plist>
PLISTEOF

echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "========================================"
echo "  构建完成!"
echo "  App: $APP_BUNDLE"
echo "  大小: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "========================================"
echo ""
file "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo ""
echo "将此 .app 拷贝到其他 Mac 即可直接使用"
echo "  支持: macOS 14.0+"
echo "  架构: $(lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/.*: //')"

rm -f "$PROJECT_DIR/$APP_NAME"
