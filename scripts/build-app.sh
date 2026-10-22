#!/bin/zsh
# Builds Clementine.app into ./build. Usage:
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --debug    debug build (faster)
#   scripts/build-app.sh --install  release build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
  esac
done

VERSION=1.0
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c $CONFIG
BIN=$(swift build -c $CONFIG --show-bin-path)/Clementine

APP=build/Clementine.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Clementine

xcrun actool Resources/Assets.xcassets --compile $APP/Contents/Resources --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist build/assets-info.plist >/dev/null

ICONSET=build/AppIcon.iconset
rm -rf $ICONSET
$BIN --render-iconset $ICONSET
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
rm -rf $ICONSET

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clementine</string>
  <key>CFBundleDisplayName</key><string>Clementine</string>
  <key>CFBundleExecutable</key><string>Clementine</string>
  <key>CFBundleIdentifier</key><string>io.github.naymid.clementine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Built with Claude Code.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists: macOS privacy grants (Desktop, Documents…)
# are tied to the signature, and ad-hoc signatures change on every build.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}')}
codesign --force --deep --sign "${SIGN_ID:--}" $APP >/dev/null
echo "Built $APP ($CONFIG, build $BUILD_NUMBER)"

if [[ $INSTALL == 1 ]]; then
  pkill -x Clementine 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Clementine.app
  cp -R $APP /Applications/Clementine.app
  open /Applications/Clementine.app
  echo "Installed to /Applications/Clementine.app"
fi
