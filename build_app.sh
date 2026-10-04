#!/bin/bash
# Builds a proper "M3 Tracker.app" bundle from the Swift package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="M3 Tracker"
BUNDLE_ID="com.smanke.MouseMileage"
APP_DIR=".build/app/${APP_NAME}.app"

echo "Building universal release binary (arm64 + x86_64)..."
# Ask SwiftPM where products go; it differs between toolchains (.build/apple
# vs .build/out), and a leftover binary at an old path would ship stale code.
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
UNIVERSAL_BIN="${BIN_DIR}/MouseMileage"

# Remove the old product so a no-op build still has to regenerate it, then
# require that the binary we package was written by this build.
BUILD_MARKER=".build/build-start-marker"
mkdir -p .build
rm -f "${UNIVERSAL_BIN}"
touch "${BUILD_MARKER}"
# The freshness check compares whole seconds, and a no-op build can finish within
# the second the marker was made; step past it so a fresh binary always reads newer.
sleep 1

swift build -c release --arch arm64 --arch x86_64

if [ ! -f "${UNIVERSAL_BIN}" ] || [ ! "${UNIVERSAL_BIN}" -nt "${BUILD_MARKER}" ]; then
  echo "error: ${UNIVERSAL_BIN} is missing or was not rebuilt by this build;" >&2
  echo "       refusing to package a stale binary." >&2
  exit 1
fi

echo "Verifying architectures..."
lipo -info "${UNIVERSAL_BIN}"

echo "Assembling app bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${UNIVERSAL_BIN}" "${APP_DIR}/Contents/MacOS/MouseMileage"
if ! cmp -s "${UNIVERSAL_BIN}" "${APP_DIR}/Contents/MacOS/MouseMileage"; then
  echo "error: packaged binary does not match ${UNIVERSAL_BIN}" >&2
  exit 1
fi
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

echo "Ad-hoc code signing (stable identifier: ${BUNDLE_ID})..."
codesign --force --deep --options runtime --identifier "${BUNDLE_ID}" --sign - "${APP_DIR}"

echo "Done: ${APP_DIR}"
echo "Move it to /Applications, then launch it, e.g.:"
echo "  cp -R \"${APP_DIR}\" /Applications/"
echo "  open \"/Applications/${APP_NAME}.app\""
