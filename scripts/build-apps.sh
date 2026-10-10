#!/bin/bash
# Universal(Apple Silicon + Intel) 앱 번들을 dist/ 에 만든다.
#   dist/iMacDisplay Sender.app    → 맥북에서 실행
#   dist/iMacDisplay Receiver.app  → iMac에서 실행
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p dist

make_app() {
    local product="$1" name="$2" bundle_id="$3" ui_element="$4"
    local app="dist/$name.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$BIN/$product" "$app/Contents/MacOS/$product"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$product</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><$ui_element/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>같은 네트워크(썬더볼트 브릿지 포함)의 iMac Display 기기를 찾고 화면을 주고받습니다.</string>
    <key>NSBonjourServices</key><array><string>_imacdisplay._tcp</string></array>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app"
    echo "만듦: $app"
}

make_app Sender   "iMacDisplay Sender"   com.waps2k.imacdisplay.sender   true
make_app Receiver "iMacDisplay Receiver" com.waps2k.imacdisplay.receiver false

lipo -info "$BIN/Sender" "$BIN/Receiver"
