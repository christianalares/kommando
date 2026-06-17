#!/usr/bin/env bash
#
# Cuts a signed, notarized, auto-updatable Kommando release.
#
#   ./scripts/release.sh <marketing-version> <build-number>
#   ./scripts/release.sh 1.0.0 1
#
# What it does:
#   1. Archives + exports a Developer ID-signed Kommando.app
#   2. Notarizes it with Apple and staples the ticket
#   3. Zips it into dist/ and (re)generates appcast.xml on the beta channel
#   4. Uploads the zip + deltas to the GitHub "downloads" release
#   5. Creates a tagged, pre-release GitHub release for these notes
#   6. Commits + pushes the updated appcast.xml
#
# Required environment (put these in scripts/release.env, which is gitignored):
#   KOMMANDO_TEAM_ID       Your Apple Developer Team ID (e.g. ABCDE12345)
#   KOMMANDO_NOTARY_PROFILE Name of the stored notarytool keychain profile
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Load local config if present.
if [[ -f scripts/release.env ]]; then
    # shellcheck disable=SC1091
    source scripts/release.env
fi

# ---- Config -----------------------------------------------------------------
SCHEME="Kommando"
APP_NAME="Kommando"
PROJECT="Kommando.xcodeproj"
GH_REPO="christianalares/kommando"
DOWNLOADS_TAG="downloads"
DOWNLOAD_URL_PREFIX="https://github.com/${GH_REPO}/releases/download/${DOWNLOADS_TAG}/"
CHANNEL="beta"

BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
GENERATE_APPCAST="$REPO_ROOT/vendor/sparkle/bin/generate_appcast"

# ---- Args & preflight -------------------------------------------------------
VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "Usage: ./scripts/release.sh <marketing-version> <build-number>" >&2
    echo "Example: ./scripts/release.sh 1.0.0 1" >&2
    exit 1
fi

: "${KOMMANDO_TEAM_ID:?Set KOMMANDO_TEAM_ID (Apple Developer Team ID) in scripts/release.env}"
: "${KOMMANDO_NOTARY_PROFILE:?Set KOMMANDO_NOTARY_PROFILE (notarytool keychain profile) in scripts/release.env}"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle tools missing. Run ./scripts/setup-tools.sh first." >&2
    exit 1
fi

ZIP_NAME="${APP_NAME}-${VERSION}.zip"
TApp="$EXPORT_DIR/$APP_NAME.app"

echo "==> Releasing $APP_NAME $VERSION (build $BUILD) on the '$CHANNEL' channel"

# ---- 1. Clean & archive -----------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Archiving"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$KOMMANDO_TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -quiet \
    archive

# ---- 2. Export with Developer ID --------------------------------------------
echo "==> Exporting (Developer ID)"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${KOMMANDO_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$TApp" ]]; then
    echo "Export failed: $TApp not found" >&2
    exit 1
fi

# ---- 3. Notarize & staple ---------------------------------------------------
echo "==> Notarizing (this can take a few minutes)"
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$TApp" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$KOMMANDO_NOTARY_PROFILE" \
    --wait

echo "==> Stapling ticket"
xcrun stapler staple "$TApp"
xcrun stapler validate "$TApp"
spctl --assess --type execute --verbose "$TApp" || true

# ---- 4. Package for Sparkle -------------------------------------------------
echo "==> Packaging $ZIP_NAME"
rm -f "$DIST_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$TApp" "$DIST_DIR/$ZIP_NAME"

# ---- 5. Generate appcast ----------------------------------------------------
echo "==> Generating appcast (channel: $CHANNEL)"
"$GENERATE_APPCAST" "$DIST_DIR" \
    --channel "$CHANNEL" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$REPO_ROOT/appcast.xml"

# ---- 6. Upload binaries to the rolling "downloads" release ------------------
echo "==> Ensuring '$DOWNLOADS_TAG' release exists"
if ! gh release view "$DOWNLOADS_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release create "$DOWNLOADS_TAG" \
        --repo "$GH_REPO" \
        --prerelease \
        --title "Downloads" \
        --notes "Hosts release archives + delta updates for Sparkle. Do not delete."
fi

echo "==> Uploading archives + deltas"
# Upload every zip/delta so the appcast's enclosure URLs resolve.
shopt -s nullglob
gh release upload "$DOWNLOADS_TAG" \
    --repo "$GH_REPO" \
    --clobber \
    "$DIST_DIR"/*.zip "$DIST_DIR"/*.delta

# ---- 7. Tagged pre-release for these notes ----------------------------------
TAG="v${VERSION}-${CHANNEL}.${BUILD}"
echo "==> Creating pre-release $TAG"
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "    Release $TAG already exists, skipping creation."
else
    gh release create "$TAG" \
        --repo "$GH_REPO" \
        --prerelease \
        --title "$APP_NAME $VERSION (beta $BUILD)" \
        --notes "Beta release. Existing testers update automatically via Sparkle.

Download: ${DOWNLOAD_URL_PREFIX}${ZIP_NAME}"
fi

# ---- 8. Publish the appcast -------------------------------------------------
echo "==> Committing appcast.xml"
git add appcast.xml
if git diff --cached --quiet; then
    echo "    appcast.xml unchanged."
else
    git commit -m "Release $APP_NAME $VERSION (beta $BUILD)"
    git push origin HEAD
fi

echo ""
echo "✅ Released $APP_NAME $VERSION (build $BUILD)."
echo "   Testers on the beta channel will be offered the update on next check."
