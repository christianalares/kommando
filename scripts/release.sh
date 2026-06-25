#!/usr/bin/env bash
#
# Cuts a signed, notarized, auto-updatable Kommando release.
#
#   ./scripts/release.sh <marketing-version> <build-number> [channel]
#   ./scripts/release.sh 0.1.3 7            # beta (default)
#   ./scripts/release.sh 1.0.0 12 stable    # stable / GM
#
# Channel:
#   beta   (default) — tagged as the "beta" channel; beta-opted testers receive it.
#   stable           — untagged; ALL users (beta and stable) receive it. Use for GM and
#                      later stable patches. Beta is the right choice while pre-1.0.
#
# What it does:
#   1. Archives + exports a Developer ID-signed Kommando.app
#   2. Notarizes it with Apple and staples the ticket
#   3. Zips it into dist/ and (re)generates appcast.xml for the chosen channel
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
# Homebrew tap that hosts the cask (brew install --cask christianalares/tap/kommando).
TAP_REPO="christianalares/homebrew-tap"
CASK_NAME="kommando"

BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
GENERATE_APPCAST="$REPO_ROOT/vendor/sparkle/bin/generate_appcast"

# ---- Args & preflight -------------------------------------------------------
VERSION="${1:-}"
BUILD="${2:-}"
CHANNEL="${3:-beta}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "Usage: ./scripts/release.sh <marketing-version> <build-number> [channel]" >&2
    echo "Example: ./scripts/release.sh 0.1.3 7         (beta, default)" >&2
    echo "         ./scripts/release.sh 1.0.0 12 stable (stable / GM)" >&2
    exit 1
fi

if [[ "$CHANNEL" != "beta" && "$CHANNEL" != "stable" ]]; then
    echo "Channel must be 'beta' or 'stable' (got '$CHANNEL')." >&2
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

# ---- Release notes ----------------------------------------------------------
# generate_appcast uses a .md/.html/.txt file whose basename matches the archive
# (e.g. Kommando-0.1.3.md next to Kommando-0.1.3.zip) as that version's release notes,
# and --embed-release-notes bakes them into appcast.xml's <description> so they show up
# in Sparkle's "What's New" sheet. The same file is reused for the GitHub release body.
NOTES_FILE=""
for _ext in md html txt; do
    _cand="$DIST_DIR/${APP_NAME}-${VERSION}.${_ext}"
    if [[ -f "$_cand" ]]; then
        NOTES_FILE="$_cand"
        break
    fi
done

if [[ -n "$NOTES_FILE" ]]; then
    echo "==> Using release notes from $(basename "$NOTES_FILE")"
else
    echo "⚠️  No release notes file found at $DIST_DIR/${APP_NAME}-${VERSION}.{md,html,txt}."
    echo "    Shipping without 'What's New' notes. (The kommando-release skill writes this file.)"
fi

echo "==> Releasing $APP_NAME $VERSION (build $BUILD) on the '$CHANNEL' channel"

# ---- 1. Clean & archive -----------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Archiving"
# Manual Developer ID signing: a directly-distributed (non-App Store) app is signed
# with the "Developer ID Application" certificate and needs no provisioning profile, so
# we avoid automatic signing's dependency on a separate Apple Development certificate.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$KOMMANDO_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    -quiet \
    archive

# ---- 1b. Bundle the MCP helper into the archive -----------------------------
# Built separately (it depends on the MCP Swift SDK) and dropped into the archived
# app so the export step signs it inside-out with the same Developer ID + hardened
# runtime as the rest of the bundle.
echo "==> Building + bundling kommando-mcp helper"
(cd "$REPO_ROOT/mcp-helper" && swift build -c release)
HELPER_BIN="$REPO_ROOT/mcp-helper/.build/release/kommando-mcp"
if [[ ! -x "$HELPER_BIN" ]]; then
    echo "Helper build failed: $HELPER_BIN not found" >&2
    exit 1
fi
ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
mkdir -p "$ARCHIVE_APP/Contents/Helpers"
cp -f "$HELPER_BIN" "$ARCHIVE_APP/Contents/Helpers/kommando-mcp"

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
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
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

# ---- 2b. Harden + re-sign the bundled helper --------------------------------
# exportArchive signs the app + Sparkle frameworks but leaves the loose executable in
# Contents/Helpers with its plain SwiftPM signature (no hardened runtime), which
# notarization rejects. Sign it inside-out: the helper first (with the hardened runtime
# and a secure timestamp), then re-seal the outer app so its CodeResources pick up the
# helper's new signature. Re-signing only the top level preserves Sparkle's nested
# framework/XPC signatures (no --deep).
echo "==> Hardening bundled kommando-mcp helper"
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application" \
    "$TApp/Contents/Helpers/kommando-mcp"

echo "==> Re-sealing app bundle"
# --preserve-metadata=entitlements keeps the entitlements the export embedded
# (microphone/camera device access, etc.); without it, this --force re-sign would
# strip them and macOS would silently deny mic/camera to child processes again.
codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements \
    --sign "Developer ID Application" \
    "$TApp"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$TApp"

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
# Stable releases are written UNTAGGED so every user (beta and stable) is offered them;
# beta releases get the "beta" channel tag so only beta-opted testers see them. Existing
# entries keep their own channel because generate_appcast preserves them from the current
# appcast.xml, so mixing a stable release into a beta history works.
echo "==> Generating appcast (channel: $CHANNEL)"
# --embed-release-notes bakes the matching notes file into <description> so testers see
# "What's New" in-app without us hosting a separate notes URL. Harmless when no file exists.
if [[ "$CHANNEL" == "stable" ]]; then
    "$GENERATE_APPCAST" "$DIST_DIR" \
        --embed-release-notes \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        -o "$REPO_ROOT/appcast.xml"
else
    "$GENERATE_APPCAST" "$DIST_DIR" \
        --embed-release-notes \
        --channel "$CHANNEL" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        -o "$REPO_ROOT/appcast.xml"
fi

# ---- 6. Upload binaries to the rolling "downloads" release ------------------
echo "==> Ensuring '$DOWNLOADS_TAG' release exists"
if ! gh release view "$DOWNLOADS_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release create "$DOWNLOADS_TAG" \
        --repo "$GH_REPO" \
        --prerelease \
        --title "Downloads" \
        --notes "Hosts release archives + delta updates for Sparkle. Do not delete."
fi

# Stable-named alias for the website's download button, so its link never changes
# across releases. Kept OUTSIDE dist/ so generate_appcast doesn't treat it as a second
# update entry; uploaded with --clobber to overwrite the previous release's copy.
ALIAS_ZIP="$BUILD_DIR/$APP_NAME.zip"
cp -f "$DIST_DIR/$ZIP_NAME" "$ALIAS_ZIP"

echo "==> Uploading archives + deltas"
# Upload every zip/delta so the appcast's enclosure URLs resolve, plus the stable alias.
shopt -s nullglob
gh release upload "$DOWNLOADS_TAG" \
    --repo "$GH_REPO" \
    --clobber \
    "$DIST_DIR"/*.zip "$DIST_DIR"/*.delta "$ALIAS_ZIP"

# ---- 7. Tagged GitHub release for these notes -------------------------------
if [[ "$CHANNEL" == "stable" ]]; then
    TAG="v${VERSION}"
    RELEASE_TITLE="$APP_NAME $VERSION"
    BLURB="Stable release. All users update automatically via Sparkle."
    PRERELEASE_FLAG=""
else
    TAG="v${VERSION}-${CHANNEL}.${BUILD}"
    RELEASE_TITLE="$APP_NAME $VERSION (beta $BUILD)"
    BLURB="Beta release. Existing testers update automatically via Sparkle."
    PRERELEASE_FLAG="--prerelease"
fi

# Build the GitHub release body: the same human notes shown in Sparkle (if any), plus a
# blurb and a stable download link.
GH_NOTES_FILE="$BUILD_DIR/gh-release-notes.md"
{
    if [[ -n "$NOTES_FILE" ]]; then
        cat "$NOTES_FILE"
        echo ""
        echo "---"
        echo ""
    fi
    echo "$BLURB"
    echo ""
    echo "Download: ${DOWNLOAD_URL_PREFIX}${ZIP_NAME}"
} > "$GH_NOTES_FILE"

echo "==> Creating release $TAG"
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "    Release $TAG already exists, skipping creation."
else
    # shellcheck disable=SC2086
    gh release create "$TAG" \
        --repo "$GH_REPO" \
        $PRERELEASE_FLAG \
        --title "$RELEASE_TITLE" \
        --notes-file "$GH_NOTES_FILE"
fi

# ---- 8. Publish the appcast -------------------------------------------------
echo "==> Committing appcast.xml"
git add appcast.xml
if git diff --cached --quiet; then
    echo "    appcast.xml unchanged."
else
    git commit -m "Release $APP_NAME $VERSION ($CHANNEL $BUILD)"
    git push origin HEAD
fi

# ---- 9. Update the Homebrew cask -------------------------------------------
# Regenerates the cask in the tap with this release's version + build + checksum so
# `brew install --cask $TAP_REPO/$CASK_NAME` always tracks the latest build. The cask
# version is "<marketing>,<build>" so it matches what Sparkle's livecheck reports.
# NOTE: this fires on every release; once a 1.0 stable line exists you may want to gate
# this to `[[ "$CHANNEL" == "stable" ]]` so beta builds don't bump the public cask.
echo "==> Updating Homebrew cask ($TAP_REPO)"
CASK_SHA256="$(shasum -a 256 "$DIST_DIR/$ZIP_NAME" | awk '{print $1}')"
TAP_CLONE="$BUILD_DIR/homebrew-tap"
rm -rf "$TAP_CLONE"
if gh repo clone "$TAP_REPO" "$TAP_CLONE" -- --depth 1 >/dev/null 2>&1; then
    mkdir -p "$TAP_CLONE/Casks"
    cat > "$TAP_CLONE/Casks/${CASK_NAME}.rb" <<EOF
cask "${CASK_NAME}" do
  version "${VERSION},${BUILD}"
  sha256 "${CASK_SHA256}"

  url "${DOWNLOAD_URL_PREFIX}${APP_NAME}-#{version.csv.first}.zip"
  name "${APP_NAME}"
  desc "Terminal with a built-in AI assistant and MCP server"
  homepage "https://github.com/${GH_REPO}"

  livecheck do
    url "https://raw.githubusercontent.com/${GH_REPO}/main/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :tahoe

  app "${APP_NAME}.app"

  zap trash: [
    "~/Library/Application Support/app.kommando.Kommando",
    "~/Library/Caches/app.kommando.Kommando",
    "~/Library/HTTPStorages/app.kommando.Kommando",
    "~/Library/Preferences/app.kommando.Kommando.plist",
    "~/Library/Saved Application State/app.kommando.Kommando.savedState",
  ]
end
EOF
    git -C "$TAP_CLONE" add "Casks/${CASK_NAME}.rb"
    if git -C "$TAP_CLONE" diff --cached --quiet; then
        echo "    Cask already up to date."
    else
        git -C "$TAP_CLONE" commit -m "${CASK_NAME} ${VERSION} (build ${BUILD})" >/dev/null
        git -C "$TAP_CLONE" push >/dev/null
        echo "    Cask bumped to ${VERSION},${BUILD}."
    fi
else
    echo "    ⚠️  Could not clone $TAP_REPO; skipping cask update (update it manually)." >&2
fi

echo ""
echo "✅ Released $APP_NAME $VERSION (build $BUILD) on the '$CHANNEL' channel."
if [[ "$CHANNEL" == "stable" ]]; then
    echo "   All users will be offered the update on next check."
else
    echo "   Testers on the beta channel will be offered the update on next check."
fi
