#!/bin/sh
# Builds the Parla iOS app on a Mac with Xcode (the Jenkins node "Spark"):
#
#   1. generates Parla.xcodeproj from project.yml with XcodeGen (installed into ~/tools if missing),
#   2. runs the unit tests of ParlaCore (lesson engine, grading, progress rules, JSON),
#   3. builds an unsigned device build -> build/dist/Parla-<version>-ios-unsigned.ipa
#      (sign it when sideloading, e.g. with Sideloadly or AltStore),
#   4. builds for the iOS Simulator -> build/dist/Parla-<version>-ios-simulator.zip
#      (install with: xcrun simctl install booted Parla.app).
#
# Usage: scripts/build-ios.sh            (from anywhere; BUILD_NUMBER from Jenkins becomes the build number)
set -eu

cd "$(dirname "$0")/.."
log() { echo "build-ios: $*" >&2; }

command -v xcodebuild >/dev/null 2>&1 || { log "xcodebuild not found - this needs a Mac with Xcode"; exit 1; }
log "using $(xcodebuild -version | head -n 1)"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)".*/\1/p' project.yml | head -n 1)
BUILD="${BUILD_NUMBER:-1}"
log "Parla $VERSION ($BUILD)"

# ---- XcodeGen
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.42.0}"
if command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN=$(command -v xcodegen)
else
  XCODEGEN="$HOME/tools/xcodegen-$XCODEGEN_VERSION/bin/xcodegen"
  if [ ! -x "$XCODEGEN" ]; then
    log "installing XcodeGen $XCODEGEN_VERSION into ~/tools"
    TMP=$(mktemp -d)
    curl -fsSL -o "$TMP/xcodegen.zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
    unzip -q "$TMP/xcodegen.zip" -d "$TMP"
    mkdir -p "$HOME/tools"
    rm -rf "$HOME/tools/xcodegen-$XCODEGEN_VERSION"
    mv "$TMP/xcodegen" "$HOME/tools/xcodegen-$XCODEGEN_VERSION"
    rm -rf "$TMP"
  fi
fi
"$XCODEGEN" generate --spec project.yml --quiet

# ---- Tests of the platform-independent part
log "running ParlaCore tests"
swift test --package-path ParlaCore

rm -rf build/dist build/ipa
mkdir -p build/dist

build() { # <destination> <products folder name>
  xcodebuild \
    -project Parla.xcodeproj \
    -scheme Parla \
    -configuration Release \
    -destination "$1" \
    -derivedDataPath build/dd \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build
  APP="build/dd/Build/Products/Release-$2/Parla.app"
  [ -d "$APP" ] || { log "$APP was not built"; exit 1; }
}

# ---- Device build, unsigned .ipa
log "building for iOS devices"
build "generic/platform=iOS" iphoneos
mkdir -p build/ipa/Payload
cp -R "build/dd/Build/Products/Release-iphoneos/Parla.app" build/ipa/Payload/
(cd build/ipa && zip -qry "../dist/Parla-$VERSION-ios-unsigned.ipa" Payload)

# ---- Simulator build
log "building for the iOS Simulator"
build "generic/platform=iOS Simulator" iphonesimulator
(cd build/dd/Build/Products/Release-iphonesimulator && zip -qry "../../../../dist/Parla-$VERSION-ios-simulator.zip" Parla.app)

log "done:"
ls -l build/dist >&2
