#!/usr/bin/env bash
#
# Builds a Release .app and packages it into a distributable DMG.
# Optionally code-signs and notarizes when the relevant env vars are present.
#
#   VERSION=0.2.0 ./Scripts/package.sh
#
# Signing / notarization env vars (all optional):
#   DEVELOPER_ID_APPLICATION  e.g. "Developer ID Application: Your Name (TEAMID)"
#   DEVELOPMENT_TEAM          e.g. "TEAMID"
#   APPLE_ID                  Apple ID email for notarytool
#   APPLE_TEAM_ID             team id for notarytool
#   APPLE_APP_PASSWORD        app-specific password for notarytool
#
set -euo pipefail

APP_NAME="Margin"
VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-1}"
DERIVED=".build-release"
DIST="dist"

rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-")
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
  )
fi

xcodegen generate

xcodebuild \
  -project Margin.xcodeproj \
  -scheme Margin \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  "${SIGN_ARGS[@]}" \
  build

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing app with hardened runtime…"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
fi

STAGING="$DIST/staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "Notarizing…"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
else
  echo "Skipping notarization (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD not set)."
fi

echo "Done: $DMG_PATH"
