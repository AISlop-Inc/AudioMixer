#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./format.sh --check
swift build -c release
app="$PWD/build/AudioMixer.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/AudioMixer "$app/Contents/MacOS/AudioMixer"
mkdir -p "$app/Contents/Resources"
ditto .build/release/AudioMixer_AudioMixer.bundle "$app/Contents/Resources/AudioMixer_AudioMixer.bundle"
for language in en ja; do
    mkdir -p "$app/Contents/Resources/$language.lproj"
    cp "Sources/Resources/$language.lproj/InfoPlist.strings" "$app/Contents/Resources/$language.lproj/InfoPlist.strings"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioMixer</string>
<key>CFBundleIdentifier</key><string>dev.mattyatea.AudioMixerPoC</string>
<key>CFBundleName</key><string>AudioMixer</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Capture audio from selected apps to adjust their volume and play it through the output device.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
for language in en ja; do
    "$app/Contents/MacOS/AudioMixer" --self-test -AppleLanguages "($language)"
done
print "Built: $app"
if [[ "${1:-}" == "--open" ]]; then
    open "$app"
fi
