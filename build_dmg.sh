#!/bin/bash

# DockMinimize DMG 打包脚本 (当前架构)
# 功能：构建并生成适合当前架构的安装包

set -e
# 确保脚本在它所在的目录下运行
cd "$(dirname "$0")"

# 配置
APP_NAME="DockMinimize"
APP_DIR="$(pwd)"
DMG_NAME="DockMinimize_Installer.dmg"
TEMP_DMG="temp_$DMG_NAME"
STAGING_DIR="dmg_staging"

echo "🚀 第一步：清理旧的构建数据..."
rm -rf "$STAGING_DIR"
rm -f "$DMG_NAME" "$TEMP_DMG"
pkill -x "$APP_NAME" 2>/dev/null || true

echo "💻 第二步：编译当前架构二进制文件..."
xcodebuild -project "$APP_NAME/$APP_NAME.xcodeproj" \
           -scheme "$APP_NAME" \
           -configuration Release \
           -derivedDataPath ".build" \
           build | grep -E "SUCCEEDED|FAILED"

echo "📦 第三步：提取 App Bundle 并注入最新资源..."
# 定位编译生成的 .app
RAW_APP=$(find .build -name "$APP_NAME.app" -type d | grep "/Release/" | head -1)
if [ -z "$RAW_APP" ]; then
    echo "❌ 错误：未找到构建产物"
    exit 1
fi

rm -rf "$APP_NAME.app"
cp -R "$RAW_APP" .

# 特别注入：确保图标是最新的并被系统识别
# 1. 注入 App 内部资源
cp "$APP_NAME/AppIcon.icns" "$APP_NAME.app/Contents/Resources/AppIcon.icns"
cp "$APP_NAME/Assets.xcassets/MenuBarIcon.imageset/menu.png" "$APP_NAME.app/Contents/Resources/menu_icon.png"

# 2. 修正 Info.plist 图标引用
plutil -replace CFBundleIconFile -string AppIcon "$APP_NAME.app/Contents/Info.plist"

# 3. 刷新系统对 Bundle 的认知
touch "$APP_NAME.app"

echo "🔐 第四步：清理扩展属性并执行 Ad-hoc 签名..."
xattr -cr "$APP_NAME.app"
codesign --force --deep --sign - "$APP_NAME.app"

echo "💿 第五步：生成 DMG 镜像..."
mkdir -p "$STAGING_DIR"
cp -r "$APP_NAME.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -srcfolder "$STAGING_DIR" -volname "$APP_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW "$TEMP_DMG"
device=$(hdiutil attach -readwrite -noverify "$TEMP_DMG" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 2
hdiutil detach "$device"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"

# 清理
rm -rf "$STAGING_DIR"
rm -f "$TEMP_DMG"
rm -rf .build

echo "----------------------------------------------------"
echo "✅ 当前架构打包完成！"
echo "📂 文件位置: $(pwd)/$DMG_NAME"
echo "----------------------------------------------------"
