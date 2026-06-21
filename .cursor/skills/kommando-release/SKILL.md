---
name: kommando-release
description: Cut a signed, notarized, auto-updating Kommando release with the correct version/build-number scheme. Use when the user wants to release Kommando, ship a build, cut a beta, publish an update, or runs /kommando-release.
---

# Kommando Release

Cuts a Developer ID-signed, notarized, Sparkle-auto-updating release of Kommando.

## Command

```bash
./scripts/release.sh <marketing-version> <build-number>
# e.g. ./scripts/release.sh 0.1.0 1
```

This archives → Developer-ID signs → hardens the bundled `kommando-mcp` helper →
notarizes → staples → zips → regenerates `appcast.xml` (beta channel) → uploads to the
GitHub `downloads` release → creates a `v<version>-beta.<build>` pre-release → commits +
pushes `appcast.xml`. Signing/notarization details are already handled inside the script.

## Versioning rules (critical)

There are two independent numbers:

- **marketing-version** (`CFBundleShortVersionString`): the human semver label.
  - Stay in `0.x.y` until the first stable GM. `1.0.0` = first GM.
  - Bug-fix beta → bump patch (`0.1.1`). New features → bump minor (`0.2.0`).
- **build-number** (`CFBundleVersion`): **must strictly increase on EVERY release, forever.**
  Sparkle decides "is there an update" by comparing the build number, NOT the version
  string. Never reuse or decrease it.

## Workflow

1. **Pick the marketing version** per the rules above (default to a `0.x.y` beta unless the
   user asks for `1.0.0`).
2. **Determine the next build number** — it must be greater than the last released build.
   Find the last one:
   ```bash
   grep -o 'sparkle:version="[0-9]*"' appcast.xml | grep -o '[0-9]*' | sort -n | tail -1
   # or: git tag -l 'v*-beta.*'
   ```
   Use `lastBuild + 1`.
3. **Commit first.** The release builds from the working tree, so commit (and usually push)
   any feature work before releasing, so the binary matches a real commit. Do not release a
   dirty tree.
4. **Run** `./scripts/release.sh <version> <build>`. It can take ~10 min (notarization is the
   slow part). Filter the noisy Swift-actor warnings if summarizing output.
5. **Confirm success**: the script ends with `✅ Released ...` and notarization shows
   `status: Accepted` then `The staple and validate action worked!`.

## Troubleshooting

**Notarization returns `status: Invalid`** → fetch the log with the submission id printed in
the output and the notary profile from `scripts/release.env` (`KOMMANDO_NOTARY_PROFILE`,
currently `kommando-notary`):

```bash
xcrun notarytool log <submission-id> --keychain-profile kommando-notary
```

Every Mach-O must have the hardened runtime + Developer ID signature + secure timestamp. The
common offender is a loose executable (e.g. `Contents/Helpers/kommando-mcp`); the script
already signs it inside-out, so if a new bundled binary appears, sign it the same way.

**`No "Mac Development" signing certificate` during archive** → the script uses manual
`Developer ID Application` signing on purpose; do not switch it back to automatic signing.

## Prerequisites (one-time, already set up on the primary Mac)

- `Developer ID Application` certificate in the login keychain (Team `73B979Z49E`).
- `scripts/release.env` (gitignored) with `KOMMANDO_TEAM_ID` and `KOMMANDO_NOTARY_PROFILE`.
- A notarytool keychain profile created via
  `xcrun notarytool store-credentials "kommando-notary" --apple-id <email> --team-id 73B979Z49E --password <app-specific-password>`.
- Sparkle tools present under `vendor/sparkle/bin/` (`./scripts/setup-tools.sh` if missing).
- `gh` authenticated for `christianalares/kommando`.
