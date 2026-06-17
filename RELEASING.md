# Releasing Kommando

Kommando ships as a **Developer ID-signed, notarized** app with **Sparkle** auto-updates.
The first releases go out on the **beta** channel, so every tester is auto-updated.

- **Appcast (update feed):** `https://raw.githubusercontent.com/christianalares/kommando/main/appcast.xml`
- **Binaries hosted on:** the GitHub `downloads` pre-release (stable URL prefix for all versions)
- **Tagged notes:** a `vX.Y.Z-beta.N` pre-release per build

---

## One-time setup

Do these once. Most are on Apple's side; a couple touch this repo.

### 1. Apple Developer Program

1. Enroll at <https://developer.apple.com/programs/> ($99/yr).
2. After approval, find your **Team ID** at <https://developer.apple.com/account> → Membership
   details (a 10-character string like `ABCDE12345`).

### 2. Developer ID Application certificate

In Xcode: **Settings → Accounts → (your Apple ID) → Manage Certificates → +
→ Developer ID Application**. This installs the signing certificate into your login keychain.

### 3. Notarization credentials

Create an **app-specific password** at <https://account.apple.com> → Sign-In and Security →
App-Specific Passwords. Then store it as a reusable notarytool profile:

```bash
xcrun notarytool store-credentials kommando-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "abcd-efgh-ijkl-mnop"   # the app-specific password
```

### 4. Sparkle signing keys (EdDSA)

```bash
./scripts/setup-tools.sh           # downloads Sparkle's CLI tools into vendor/
./vendor/sparkle/bin/generate_keys # creates a keypair; private key goes to the Keychain
```

`generate_keys` prints a **public key**. Paste it into the project: replace
`REPLACE_WITH_SPARKLE_PUBLIC_KEY` in `Kommando.xcodeproj/project.pbxproj`
(the `INFOPLIST_KEY_SUPublicEDKey` value, two places).

> Keep the private key safe — it lives in your login Keychain. If you lose it, existing
> installs can't verify future updates and testers must reinstall manually.

### 5. Local release config

Create `scripts/release.env` (gitignored):

```bash
KOMMANDO_TEAM_ID="ABCDE12345"
KOMMANDO_NOTARY_PROFILE="kommando-notary"
```

---

## Cutting a release

Bump the build number every time (Sparkle compares `CFBundleVersion`). Marketing version
is the human-facing string.

```bash
./scripts/release.sh 1.0.0 1     # first beta
./scripts/release.sh 1.0.0 2     # next beta build, same version
./scripts/release.sh 1.1.0 3     # new version
```

The script archives, signs with Developer ID, notarizes + staples, zips into `dist/`,
regenerates `appcast.xml`, uploads the archive (+ deltas) to the `downloads` release,
creates a `vX.Y.Z-beta.N` pre-release, and commits/pushes the appcast.

### Keep `dist/`

`dist/` (gitignored) accumulates every release archive. Sparkle needs the old archives to
build delta updates and to keep historical appcast entries. Don't delete it; back it up if
you switch machines.

---

## How testers get it

- **First install:** send them the download link, e.g.
  `https://github.com/christianalares/kommando/releases/download/downloads/Kommando-1.0.0.zip`
  (or point them at the latest pre-release). They unzip and drag to `/Applications`.
- **Updates:** automatic. Sparkle checks the appcast on launch and prompts to install. They
  can also trigger it via **Kommando → Check for Updates…**.

---

## Going from beta to stable (later)

The app currently subscribes to the `beta` channel (`BetaUpdaterDelegate` in
`Kommando/Support/Updater.swift`). When you're ready for a public stable track, cut that
release **without** `--channel beta` so untagged items reach everyone, and decide whether
the shipping build should keep listening to `beta`.
