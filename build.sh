#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
app="$PWD/build/AudioMixer.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/AudioMixer "$app/Contents/MacOS/AudioMixer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioMixer</string>
<key>CFBundleIdentifier</key><string>dev.mattyatea.AudioMixerPoC</string>
<key>CFBundleName</key><string>AudioMixer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>選択したアプリの音声を取り込み、音量を調整して出力します。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/AudioMixer" --self-test
print "Built: $app"
if [[ "${1:-}" == "--open" ]]; then open "$app"; fi
