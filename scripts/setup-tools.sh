#!/usr/bin/env bash
#
# Downloads Sparkle's command-line tools (generate_keys, generate_appcast, sign_update)
# into ./vendor/sparkle. Run this once on each machine you cut releases from.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor/sparkle"

echo "==> Resolving latest Sparkle release"
TAG="$(gh api repos/sparkle-project/Sparkle/releases/latest --jq .tag_name)"
echo "    Latest Sparkle: $TAG"

ASSET_URL="https://github.com/sparkle-project/Sparkle/releases/download/${TAG}/Sparkle-${TAG}.tar.xz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Downloading $ASSET_URL"
curl -fsSL "$ASSET_URL" -o "$TMP_DIR/sparkle.tar.xz"

echo "==> Extracting tools into $VENDOR_DIR"
mkdir -p "$VENDOR_DIR/bin"
tar -xf "$TMP_DIR/sparkle.tar.xz" -C "$TMP_DIR"

# Locate the tools wherever the tarball places them and copy into vendor/sparkle/bin.
for tool in generate_keys generate_appcast sign_update BinaryDelta; do
    src="$(find "$TMP_DIR" -type f -name "$tool" -perm -u+x -print -quit)"
    if [[ -n "$src" ]]; then
        cp "$src" "$VENDOR_DIR/bin/"
    fi
done

echo "==> Done. Tools available at:"
ls -1 "$VENDOR_DIR/bin"
