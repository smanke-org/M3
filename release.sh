#!/bin/bash
# Builds, Developer-ID-signs, notarizes, and staples "M3 Tracker.app" for
# distribution outside the Mac App Store, then zips it for upload/download.
#
# One-time setup before running this:
#   1. In Xcode: Settings -> Accounts -> your team -> Manage Certificates ->
#      "+" -> Developer ID Application. This installs a signing identity.
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials "M3TrackerNotary" \
#          --apple-id "you@example.com" \
#          --team-id "YOURTEAMID" \
#          --password "an-app-specific-password"
#      (generate the app-specific password at appleid.apple.com; team ID is
#      shown next to your Developer ID Application identity, or in
#      developer.apple.com/account -> Membership details)
#
# Then run:
#   ./release.sh "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

cd "$(dirname "$0")"

SIGNING_IDENTITY="${1:?Usage: ./release.sh \"Developer ID Application: Your Name (TEAMID)\"}"
NOTARY_PROFILE="${NOTARY_PROFILE:-M3TrackerNotary}"

APP_NAME="M3 Tracker"
BUNDLE_ID="com.smanke.MouseMileage"
APP_DIR=".build/app/${APP_NAME}.app"
ZIP_PATH=".build/app/${APP_NAME}.zip"

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

echo "Signing with Developer ID (identifier: ${BUNDLE_ID})..."
codesign --force --deep --options runtime --timestamp \
  --identifier "${BUNDLE_ID}" \
  --sign "${SIGNING_IDENTITY}" \
  "${APP_DIR}"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Zipping for notarization..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "Submitting to Apple notary service (profile: ${NOTARY_PROFILE})..."
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "${APP_DIR}"

echo "Final Gatekeeper check..."
spctl -a -vvv --type execute "${APP_DIR}"

echo "Re-zipping stapled app for distribution..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo ""
echo "Done. Distributable app: ${APP_DIR}"
echo "Distributable zip:       ${ZIP_PATH}"
