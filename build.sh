#!/bin/bash
# WiFiDoctor をビルドして .app バンドルを作る。
# バンドル + 署名が無いと位置情報(SSID/BSSID取得)と通知の許可が取れないため、
# 単体バイナリではなく必ず .app を作る。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WiFiDoctor.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc -O \
  -framework AppKit -framework SwiftUI -framework CoreWLAN -framework CoreLocation \
  -framework UserNotifications -framework ServiceManagement \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/WiFiDoctor"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier dev.yukagil.wifidoctor "$APP"

# ログイン項目はアプリのパスを覚えるため、ビルドフォルダから起動していると
# フォルダを動かした瞬間に壊れる。安定した ~/Applications へ設置する。
DEST="$HOME/Applications/WiFiDoctor.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
codesign --force --sign - --identifier dev.yukagil.wifidoctor "$DEST"

echo "==> built:     $(pwd)/$APP"
echo "==> installed: $DEST"
