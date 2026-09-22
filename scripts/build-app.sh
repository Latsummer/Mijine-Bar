#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/Mijine Bar.app"
ASSET_OUTPUT_DIR="$BUILD_DIR/asset-catalog"

export DEVELOPER_DIR
export TMPDIR="$BUILD_DIR/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swiftpm-module-cache"

mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
mkdir -p "$ASSET_OUTPUT_DIR"

cd "$PROJECT_DIR"
swift build --disable-sandbox -c release
xcrun actool \
    --compile "$ASSET_OUTPUT_DIR" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_OUTPUT_DIR/AppIconInfo.plist" \
    "$PROJECT_DIR/AppResources/Assets.xcassets"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/zh-Hans.lproj"
cp "$BUILD_DIR/release/PallerKeyboard" "$APP_DIR/Contents/MacOS/PallerKeyboard"
cp "$PROJECT_DIR/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/AppResources/KrustyKrab.jpg" "$APP_DIR/Contents/Resources/KrustyKrab.jpg"
cp "$PROJECT_DIR/AppResources/FishboneTemplate.png" "$APP_DIR/Contents/Resources/FishboneTemplate.png"
cp "$PROJECT_DIR/AppResources/FishboneTemplate@2x.png" "$APP_DIR/Contents/Resources/FishboneTemplate@2x.png"
cp "$ASSET_OUTPUT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ASSET_OUTPUT_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
cp "$PROJECT_DIR/AppResources/zh-Hans.lproj/InfoPlist.strings" "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

SIGN_IDENTITY="${PALLER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign \
        --force \
        --options runtime \
        --timestamp=none \
        --sign "$SIGN_IDENTITY" \
        --identifier com.paller.keyboard-wallpaper.demo \
        "$APP_DIR"
    echo "Signed with: $SIGN_IDENTITY"
else
    codesign --force --sign - --identifier com.paller.keyboard-wallpaper.demo "$APP_DIR"
    echo "Warning: no Apple Development identity found; used an ad-hoc signature."
fi

touch "$APP_DIR"
echo "$APP_DIR"
