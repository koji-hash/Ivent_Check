#!/bin/zsh
# mac_location.swift を小さな Mac アプリ（WhereAmI.app）にまとめる。
# アプリにすると macOS が位置情報の許可ダイアログを出せる（コマンドラインのままだと拒否される）。
set -euo pipefail
cd "$(dirname "$0")"
app=build/WhereAmI.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.ivent-check.whereami</string>
	<key>CFBundleName</key><string>現在地取得</string>
	<key>CFBundleExecutable</key><string>WhereAmI</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSUIElement</key><true/>
	<key>NSLocationUsageDescription</key><string>iOSシミュレータの位置をこのMacの現在地に合わせるために使用します。</string>
	<key>NSLocationWhenInUseUsageDescription</key><string>iOSシミュレータの位置をこのMacの現在地に合わせるために使用します。</string>
</dict>
</plist>
PLIST
swiftc -O mac_location.swift -o "$app/Contents/MacOS/WhereAmI"
xattr -cr "$app"
codesign --force --sign - "$app"
echo "$app"
