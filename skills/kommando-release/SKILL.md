---
name: kommando-release
description: Cut a signed, notarized, auto-updating Kommando release with the correct version/build-number scheme. Use when the user wants to release Kommando, ship a build, cut a beta, publish an update, or runs /kommando-release.
---

# Kommando Release

Cuts a Developer ID-signed, notarized, Sparkle-auto-updating release of Kommando.

## Command

```bash
./scripts/release.sh <marketing-version> <build-number> [channel]
# beta (default):  ./scripts/release.sh 0.1.3 7
# stable / GM:     ./scripts/release.sh 1.0.0 12 stable
```

This archives → Developer-ID signs → hardens the bundled `kommando-mcp` helper →
notarizes → staples → zips → regenerates `appcast.xml` (embedding any release notes) →
uploads to the GitHub `downloads` release → creates a tagged GitHub release → commits +
pushes `appcast.xml` → bumps the Homebrew cask in `christianalares/homebrew-tap`. Signing
and notarization details are already handled inside the script.

## Channel — do NOT ask the user every time

The channel is determined by the release lifecycle, not a per-release choice, so don't
prompt for it:

- **Default to `beta`** (omit the 3rd arg). While Kommando is pre-1.0 every release is a
  beta — this is the normal case.
- **Use `stable` only for the `1.0.0` GM and later stable patches**, i.e. when the
  marketing version is `>= 1.0.0`, or if the user explicitly says "stable release".

How channels reach users (standard Sparkle model):

- `beta` releases are tagged with the `beta` channel — only testers with the beta toggle on
  (the pre-1.0 default) are offered them.
- `stable` releases are written **untagged** — every user (beta and stable) is offered them.

First stable (`1.0.0`) note: the stable path is wired but hasn't been exercised yet. On the
first GM, verify the generated `appcast.xml` keeps prior beta entries tagged `beta` while
the new `1.0.0` entry has no `<sparkle:channel>`, before pushing.

## Homebrew cask — updated automatically

The last step of `release.sh` regenerates the cask in the
[`christianalares/homebrew-tap`](https://github.com/christianalares/homebrew-tap) repo so
users on `brew install --cask christianalares/tap/kommando` always get the latest build. It
clones the tap, rewrites `Casks/kommando.rb` with this release's version + build + sha256,
and commits/pushes. No manual step needed.

Details that matter if you ever touch it:

- The cask `version` is `"<marketing>,<build>"` (e.g. `0.3.2,7`) so it matches what
  Sparkle's livecheck reports; the download URL uses `#{version.csv.first}` for the zip name.
- `auto_updates true` is set (Sparkle self-updates), and `depends_on macos: :tahoe` mirrors
  the app's `LSMinimumSystemVersion` (26.0).
- It fires on **every** release, including betas — correct while pre-1.0. Once a `1.0`
  stable line exists, consider gating the cask bump to `CHANNEL == "stable"` (there's a
  comment marking the spot in `release.sh`) so beta builds don't reach stable cask users.
- The `downloads` GitHub release must NOT be flagged as a pre-release (it's just an asset
  host) or `brew audit` complains. The per-version `v*-beta*` releases stay pre-release.

## Release notes — ALWAYS confirm the bullets first

Every release should ship "What's New" notes that appear inside the app's Sparkle update
sheet, not just on GitHub. The mechanism:

- `generate_appcast` picks up a `dist/<APP>-<VERSION>.{md,html,txt}` file whose basename
  matches the archive (e.g. `dist/Kommando-0.1.3.md` for `Kommando-0.1.3.zip`).
- `release.sh` passes `--embed-release-notes`, so those notes are **baked into
  `appcast.xml`'s `<description>`** — testers see them in-app on update, with no separately
  hosted/signed notes file. The same file is reused as the GitHub release body.
- If the file is missing, the script still releases but prints a warning and ships no
  "What's New" notes.

So before releasing, do this:

1. **Draft the bullets** from what actually changed since the last release:
   ```bash
   git log "$(git describe --tags --abbrev=0)..HEAD" --oneline
   ```
   Rewrite them as short, user-facing bullets (features/fixes the user cares about — not raw
   commit subjects). Markdown, e.g.:
   ```markdown
   ### What's new
   - Command blocks: click a command to select it, ⌥↑/↓ to cycle, ⌘C to copy
   - Right-click context menu in the terminal (copy / paste / clear)

   ### Fixes
   - More reliable block highlighting after clearing the screen
   ```
2. **Show the bullet list to the user and get explicit approval (or edits) before
   proceeding.** Do not release until they confirm. This is the one manual gate.
3. **Write the approved notes** to `dist/<APP>-<VERSION>.md` (the `dist/` dir persists
   between releases; the script does not wipe it).
4. Then run `release.sh` as normal.

Markdown rendering in Sparkle's sheet requires macOS 12+ (Kommando is macOS 26-only, so
fine). On the **first** release cut with this flow, after publishing, open
**Kommando → Check for Updates…** on an older build and confirm the notes render correctly;
if they don't, switch the file to a small HTML fragment (`<h3>`/`<ul><li>`, no `<html>`/
`<body>`), which Sparkle embeds and renders identically.

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
   grep -o '<sparkle:version>[0-9]*</sparkle:version>' appcast.xml | grep -o '[0-9]*' | sort -n | tail -1
   # (counts both beta and stable entries — build numbers are shared across channels)
   ```
   Use `lastBuild + 1`.
3. **Draft + confirm release notes** (see "Release notes" above): summarize changes since
   the last tag into user-facing bullets, get the user's approval, then write them to
   `dist/<APP>-<VERSION>.md`. Don't proceed past this step without confirmation.
4. **Commit first.** The release builds from the working tree, so commit (and usually push)
   any feature work before releasing, so the binary matches a real commit. Do not release a
   dirty tree.
5. **Run** `./scripts/release.sh <version> <build> [channel]` (channel defaults to beta — see
   "Channel"). It can take ~10 min (notarization is the slow part). Filter the noisy
   Swift-actor warnings if summarizing output.
6. **Confirm success**: the script ends with `✅ Released ...` and notarization shows
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
- `gh` authenticated for `christianalares/kommando` **and** `christianalares/homebrew-tap`
  (the cask-bump step clones and pushes to the tap).
