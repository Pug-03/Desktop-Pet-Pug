#!/bin/bash
# Builds Pug.app (universal: Apple Silicon + Intel) into ./build
set -euo pipefail
cd "$(dirname "$0")"

python3 tools/extract.py
python3 tools/desk.py
python3 tools/build_sprites.py
python3 tools/make_icon.py

APP=build/Pug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" \
    App/Sources/*.swift -o "build/Pug-$arch"
done
lipo -create build/Pug-arm64 build/Pug-x86_64 -output "$APP/Contents/MacOS/Pug"
rm build/Pug-arm64 build/Pug-x86_64

cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/Resources/sprites App/Resources/messages.json App/Resources/messages.th.json App/Resources/schedule.html App/Resources/letter.html App/Resources/letter.json App/Resources/letter.th.json App/Resources/guide.html App/Resources/guide "$APP/Contents/Resources/"
[ -f App/Resources/AppIcon.icns ] && cp App/Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep -s - "$APP"

# what the app's "Check for updates" reads: bump CFBundleVersion in App/Info.plist for every release
rm -f Pug.zip
ditto -c -k --keepParent "$APP" Pug.zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" App/Info.plist)
printf '{"version": "%s", "build": %s}\n' "$VERSION" "$BUILD" > latest.json
echo "built $APP, Pug.zip and latest.json ($VERSION, build $BUILD)"
