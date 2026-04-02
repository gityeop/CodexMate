# CodexMate Packaging and Release

This document covers packaging the app, notarizing it, and generating release artifacts.

## Package the App

Create a release-style `.app` bundle:

```bash
./scripts/package_app.sh
```

`package_app.sh` expects `APPLE_SIGN_IDENTITY` for a distributable build. Use `ALLOW_ADHOC_SIGNING=1` only when you explicitly want a local unsigned or ad-hoc dry run that will fail Gatekeeper checks and show no Developer ID signer.

Optional environment variables:

```bash
APP_VERSION=42 \
APP_SHORT_VERSION=0.4.2 \
CODEXMATE_BUNDLE_ID=com.example.codexmate \
SPARKLE_FEED_URL=https://github.com/your-org/your-repo/releases/latest/download/appcast.xml \
SPARKLE_PUBLIC_KEY=... \
APPLE_SIGN_IDENTITY="Developer ID Application: ..." \
APPLE_KEYCHAIN_PASSWORD='your-login-keychain-password' \
./scripts/package_app.sh
```

If `SPARKLE_FEED_URL` is omitted, `package_app.sh` tries to derive `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` from `origin` when the repository remote is GitHub. If `SPARKLE_PUBLIC_KEY` is omitted, `package_app.sh` tries to resolve it from the Sparkle keychain account named by `SPARKLE_KEYCHAIN_ACCOUNT`. If it still cannot resolve the key, the app is packaged but automatic updates stay unavailable in Settings until the bundle is rebuilt with Sparkle metadata.

If `APPLE_KEYCHAIN_PASSWORD` is set, the packaging script unlocks the keychain and configures codesign access up front so macOS does not repeatedly prompt for the signing key during the nested Sparkle and framework signing steps. Set `APPLE_KEYCHAIN_PATH` as well if you do not use the default login keychain.

Expected output:

```text
dist/CodexMate.app
```

## Notarize the App

To notarize a signed app:

```bash
APPLE_NOTARY_PROFILE=your-notarytool-profile ./scripts/notarize_app.sh
```

## Create a Release Archive

Create a signed release archive and Sparkle appcast entry:

```bash
APP_VERSION=42 \
APP_SHORT_VERSION=0.4.2 \
APPLE_SIGN_IDENTITY="Developer ID Application: ..." \
APPLE_KEYCHAIN_PASSWORD='your-login-keychain-password' \
APPLE_NOTARY_PROFILE=your-notarytool-profile \
SPARKLE_APPCAST_URL=https://github.com/your-org/your-repo/releases/latest/download/appcast.xml \
SPARKLE_PUBLIC_KEY=... \
RELEASE_NOTES_FILE=/absolute/path/to/release-notes/0.4.2.html \
./scripts/release_app.sh
```

The release script reuses the packaged `.app`, optionally notarizes and staples it, creates a final zip archive, and generates an updated Sparkle appcast in `dist/release`.

Optional environment variables:

```bash
SPARKLE_DOWNLOAD_URL_PREFIX=https://github.com/your-org/your-repo/releases/latest/download \
SPARKLE_KEYCHAIN_ACCOUNT=ed25519 \
SPARKLE_PRIVATE_KEY_FILE=/absolute/path/to/sparkle-private-key \
SPARKLE_PRIVATE_KEY_SECRET=... \
RELEASE_LINK=https://github.com/your-org/your-repo/releases/tag/v0.4.2 \
RELEASE_DIR=/absolute/path/to/output-dir \
./scripts/release_app.sh
```

## Local Dry Run

For a local dry run without Developer ID signing or notarization:

```bash
APP_VERSION=42 \
APP_SHORT_VERSION=0.4.2 \
ALLOW_ADHOC_SIGNING=1 \
SKIP_NOTARIZATION=1 \
SPARKLE_APPCAST_URL=https://github.com/your-org/your-repo/releases/latest/download/appcast.xml \
RELEASE_NOTES_FILE=/absolute/path/to/release-notes/0.4.2.html \
./scripts/release_app.sh
```

If `SPARKLE_PUBLIC_KEY` is omitted, `release_app.sh` looks it up from the Sparkle keychain account named by `SPARKLE_KEYCHAIN_ACCOUNT`. To avoid Sparkle-related keychain prompts in unattended releases, set `SPARKLE_PUBLIC_KEY` and either `SPARKLE_PRIVATE_KEY_FILE` or `SPARKLE_PRIVATE_KEY_SECRET` so the release flow does not need to read the Sparkle key from Keychain Access.

Expected release outputs:

```text
dist/release/CodexMate-0.4.2.zip
dist/release/CodexMate-0.4.2.html
dist/release/appcast.xml
```
