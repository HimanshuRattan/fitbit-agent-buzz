#!/bin/zsh
# Builds build/Fitbit Buzz.app: the menu bar app plus the Golden Gate tools it runs.
# No Xcode needed; uses swiftc from the Command Line Tools.
# Run scripts/build-golden-gate.sh first to produce vendor/bin.
set -eu
ROOT="${0:A:h:h}"
APP="$ROOT/build/Fitbit Buzz.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Fitbit Buzz</string>
<key>CFBundleIdentifier</key><string>dev.notify-fitbit.menubar</string>
<key>CFBundleExecutable</key><string>FitbitBuzz</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connects to your Fitbit Air to buzz it when your coding agent needs you.</string>
<key>FitbitBuzzScript</key><string>$ROOT/bin/fitbit-buzz</string>
</dict></plist>
EOF

[[ -x "$ROOT/vendor/bin/gg-stack-tool" ]] || { echo "Missing vendor/bin; run scripts/build-golden-gate.sh first"; exit 1; }
swiftc -O "$ROOT/app/FitbitBuzz.swift" -o "$APP/Contents/MacOS/FitbitBuzz"
cp "$ROOT/vendor/bin/gg-stack-tool" "$ROOT/vendor/bin/gg-coap-client" "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
