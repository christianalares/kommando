#!/usr/bin/env bash
#
# Builds the kommando-mcp helper and (optionally) installs it into an app bundle's
# Contents/Helpers, ad-hoc signing it so it runs locally.
#
#   ./scripts/build-mcp-helper.sh [/path/to/Kommando.app]
#
# With no argument it just builds the binary and prints its path.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_DIR="$REPO_ROOT/mcp-helper"
APP_PATH="${1:-}"

echo "==> Building kommando-mcp helper (release)"
(cd "$HELPER_DIR" && swift build -c release)

BIN="$HELPER_DIR/.build/release/kommando-mcp"
if [[ ! -x "$BIN" ]]; then
    echo "Build failed: $BIN not found" >&2
    exit 1
fi
echo "==> Built $BIN"

if [[ -n "$APP_PATH" ]]; then
    if [[ ! -d "$APP_PATH" ]]; then
        echo "App bundle not found: $APP_PATH" >&2
        exit 1
    fi
    DEST="$APP_PATH/Contents/Helpers"
    mkdir -p "$DEST"
    cp -f "$BIN" "$DEST/kommando-mcp"
    codesign --force --sign - "$DEST/kommando-mcp"
    echo "==> Installed + ad-hoc signed helper at $DEST/kommando-mcp"
fi
