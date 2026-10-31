#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *) echo "用法：scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
swift build -c "$configuration" --arch arm64
bin_path="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app_path="$PWD/build/DayOrder.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
cp "$bin_path/DayOrder" "$app_path/Contents/MacOS/DayOrder"
ditto "$bin_path/DayOrder_DayOrderCore.bundle" "$app_path/Contents/Resources/DayOrder_DayOrderCore.bundle"
ditto "$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
cp "$PWD/.build/artifacts/sparkle/Sparkle/LICENSE" "$app_path/Contents/Resources/Sparkle-LICENSE"
swift scripts/generate-icon.swift "$PWD/Assets/AppIcon.png" "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DayOrder</string>
  <key>CFBundleIdentifier</key><string>com.dayorder.calendar</string>
  <key>CFBundleName</key><string>DayOrder</string>
  <key>CFBundleDisplayName</key><string>日序</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>48</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>https://github.com/hygao1024/day-order/releases/latest/download/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUEnableSystemProfiling</key><false/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
python3 - "$app_path/Contents/Info.plist" "$PWD/Assets/UpdatePublicKey.pub" <<'PY'
import base64
import pathlib
import plistlib
import sys
path = pathlib.Path(sys.argv[1])
key = pathlib.Path(sys.argv[2]).read_text().strip()
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("更新公钥必须是 32 字节的 Ed25519 公钥。")
info = plistlib.loads(path.read_bytes())
info["SUPublicEDKey"] = key
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
echo "已构建 $app_path"
