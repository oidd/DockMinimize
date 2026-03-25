#!/bin/bash

# DockMinimize 通用版 DMG 打包脚本
# 功能：构建通用架构安装包（arm64 + x86_64）

set -e
# 确保脚本在它所在的目录下运行
cd "$(dirname "$0")"

# 配置
APP_NAME="DockMinimize"
APP_DIR="$(pwd)"
DMG_NAME="DockMinimize.dmg"
TEMP_DMG="temp_$DMG_NAME"
STAGING_DIR="dmg_staging"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "🚀 第一步：清理旧的构建数据..."
rm -rf "$STAGING_DIR"
rm -f "$DMG_NAME" "$TEMP_DMG"
pkill -x "$APP_NAME" 2>/dev/null || true

echo "💻 第二步：编译通用架构二进制文件 (arm64 + x86_64)..."
xcodebuild -project "$APP_NAME/$APP_NAME.xcodeproj" \
           -scheme "$APP_NAME" \
           -configuration Release \
           -derivedDataPath ".build" \
           ARCHS="arm64 x86_64" \
           ONLY_ACTIVE_ARCH=NO \
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

# 注入推荐工具图标
mkdir -p "$APP_NAME.app/Contents/Resources/Recommends"
cp -R "$APP_NAME/Resources/Recommends/" "$APP_NAME.app/Contents/Resources/Recommends/"

# 2. 修正 Info.plist 图标引用
plutil -replace CFBundleIconFile -string AppIcon "$APP_NAME.app/Contents/Info.plist"

# 3. 刷新系统对 Bundle 的认知
touch "$APP_NAME.app"

echo "🔐 第四步：清理扩展属性并使用 Developer ID Application 证书签名..."
xattr -cr "$APP_NAME.app"
if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "⚠️ 已启用 SKIP_SIGN=1，跳过 codesign。"
else
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "❌ 错误：未找到可用的 Developer ID Application 签名证书。"
        echo "请在钥匙串中确认该证书和私钥可用，或通过 SIGN_IDENTITY 指定正确证书。"
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
        echo "❌ 错误：未找到可用的 Developer ID Application 签名证书。"
        echo "请在钥匙串中确认该证书和私钥可用，或通过 SIGN_IDENTITY 指定正确证书。"
        exit 1
    fi
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime "$APP_NAME.app"
fi

echo "💿 第五步：生成 DMG 镜像..."
mkdir -p "$STAGING_DIR"
cp -r "$APP_NAME.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -srcfolder "$STAGING_DIR" -volname "$APP_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW "$TEMP_DMG"
device=$(hdiutil attach -readwrite -noverify "$TEMP_DMG" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 2
hdiutil detach "$device"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"

if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "🧾 第六步：提交 Apple 公证并装订票据..."
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "❌ 错误：已启用 NOTARIZE=1，但未提供 NOTARY_PROFILE。"
        echo "请先执行：xcrun notarytool store-credentials <profile-name> ..."
        echo "再使用：NOTARIZE=1 NOTARY_PROFILE=<profile-name> ./build_dmg.sh"
        exit 1
    fi

    xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_NAME.app"
    xcrun stapler staple "$DMG_NAME"

    echo "✅ 公证完成并已装订票据。"
fi

# 清理
rm -rf "$STAGING_DIR"
rm -f "$TEMP_DMG"
rm -rf .build

echo "----------------------------------------------------"
echo "✅ 通用架构打包完成！"
echo "📂 文件位置: $(pwd)/$DMG_NAME"
echo "💻 兼容性：支持 Intel 芯片 + Apple 芯片"
echo "----------------------------------------------------"
