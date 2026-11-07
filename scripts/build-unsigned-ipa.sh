#!/usr/bin/env bash
# Builds OverAir.app for real devices without code signing and packages it as an .ipa
# you can sign yourself (Sideloadly, AltStore, SideStore, iOS App Signer, zsign, etc.).
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
mkdir -p build
rm -rf build/Payload build/OverAir-unsigned.ipa

xcodebuild \
  -project OverAir.xcodeproj \
  -scheme OverAir \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | tee build/xcodebuild.log | grep -E "error:|warning: .*(deprecated)|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release-iphoneos/OverAir.app"
if [ ! -d "$APP" ]; then
  echo "Build failed — see build/xcodebuild.log"
  grep -E "error:" build/xcodebuild.log | head -50 || true
  exit 1
fi

mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry OverAir-unsigned.ipa Payload)
rm -rf build/Payload
echo "✅ build/OverAir-unsigned.ipa"
