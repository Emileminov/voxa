#!/bin/bash
# Релиз: сборка + подпись Developer ID + нотаризация приложения (+штамп) + DMG (тоже нотаризован).
# Профиль нотаризации уже в связке ключей (как у других проектов): launchpad-notary
set -e
cd "$(dirname "$0")"
ID="${SIGN_ID:-Developer ID Application: Emil EMINOV (4AR298V292)}"
PROFILE="${NOTARY_PROFILE:-launchpad-notary}"
APP="Voxa.app"; DMG="Voxa.dmg"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"; cp icon/AppIcon.icns "$APP/Contents/Resources/"
./bundle_whisper.sh "$APP"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Voxa" main.swift
# подписываем вложенные бинарники отдельно, затем всё приложение
for f in "$APP"/Contents/Resources/whisper/bin/*.so "$APP"/Contents/Resources/whisper/lib/*; do codesign --force --options runtime --timestamp --sign "$ID" "$f"; done
# whisper-cli: нужны disable-library-validation / JIT, иначе Metal не подгружается и расшифровка идёт на CPU (очень медленно)
codesign --force --options runtime --timestamp --entitlements whisper.entitlements --sign "$ID" "$APP"/Contents/Resources/whisper/bin/whisper-cli
codesign --force --deep --options runtime --timestamp --entitlements entitlements.plist --sign "$ID" "$APP"
codesign --verify --deep --strict "$APP"

rm -f app.zip; ditto -c -k --keepParent "$APP" app.zip
xcrun notarytool submit app.zip --keychain-profile "$PROFILE" --wait
rm -f app.zip
xcrun stapler staple "$APP"

rm -rf dmg_root "$DMG"; mkdir dmg_root
cp -R "$APP" dmg_root/; ln -s /Applications dmg_root/Applications
hdiutil create -volname "Voxa" -srcfolder dmg_root -ov -format UDZO "$DMG" >/dev/null
rm -rf dmg_root
codesign --force --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute -v "$APP" || true
spctl --assess --type open --context context:primary-signature -v "$DMG" || true
echo "Готово: $(pwd)/$DMG"
