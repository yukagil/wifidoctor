#!/bin/bash
# WiFiDoctor をビルドして .app バンドルを作る。
# バンドル + 署名が無いと位置情報(SSID/BSSID取得)と通知の許可が取れないため、
# 単体バイナリではなく必ず .app を作る。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WiFiDoctor.app"

# 対応する最低OS。ここを Info.plist と一致させないと、
# 「13.0以上で動く」と宣言しながら実際にはビルドした機械のOS未満で起動しない、
# という状態になる（利用者からは「開いた瞬間に落ちる」に見える）。
MIN_MACOS="14.0"
PLIST_MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
if [ "$MIN_MACOS" != "$PLIST_MIN" ]; then
  echo "!! ビルドの最低OS($MIN_MACOS) と Info.plist($PLIST_MIN) が違う" >&2
  exit 1
fi

FRAMEWORKS="-framework AppKit -framework SwiftUI -framework CoreWLAN -framework CoreLocation
            -framework UserNotifications -framework ServiceManagement"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Intel と Apple Silicon の両方で動くようにする。
# 片方だけだと、もう片方の機械では起動すらできない。
echo "==> compiling (arm64 + x86_64, macOS $MIN_MACOS+)"
for ARCH in arm64 x86_64; do
  swiftc -O -target "${ARCH}-apple-macos${MIN_MACOS}" $FRAMEWORKS \
    Sources/*.swift -o "build/wd-${ARCH}"
done
lipo -create build/wd-arm64 build/wd-x86_64 -output "$APP/Contents/MacOS/WiFiDoctor"
rm -f build/wd-arm64 build/wd-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/WiFiDoctor.icns ] && cp Resources/WiFiDoctor.icns "$APP/Contents/Resources/"

# 宣言どおりの最低OSでビルドされたかを、バイナリ側から確かめる。
BUILT_MIN=$(otool -l "$APP/Contents/MacOS/WiFiDoctor" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
if [ "$BUILT_MIN" != "$MIN_MACOS" ]; then
  echo "!! バイナリの最低OS($BUILT_MIN) が宣言($MIN_MACOS)と違う" >&2
  exit 1
fi
ARCHS=$(lipo -archs "$APP/Contents/MacOS/WiFiDoctor")
echo "==> arch: $ARCHS / minos: $BUILT_MIN"

# 署名。Developer ID があればそれを使い、公証できる形（Hardened Runtime）にする。
# 無ければ ad-hoc に落ちるが、その .app は自分の機械でしか動かない。
if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> signing (Developer ID)"
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID" --identifier dev.yukagil.wifidoctor "$APP"
else
  echo "==> signing (ad-hoc: この .app は他人の機械では Gatekeeper に止められる)"
  codesign --force --sign - --identifier dev.yukagil.wifidoctor "$APP"
fi

# ログイン項目はアプリのパスを覚えるため、ビルドフォルダから起動していると
# フォルダを動かした瞬間に壊れる。安定した ~/Applications へ設置する。
DEST="$HOME/Applications/WiFiDoctor.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID" --identifier dev.yukagil.wifidoctor "$DEST"
else
  codesign --force --sign - --identifier dev.yukagil.wifidoctor "$DEST"
fi

echo "==> built:     $(pwd)/$APP"
echo "==> installed: $DEST"
