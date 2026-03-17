# CodextensionMenubar

Small macOS menu bar app that launches `codex app-server --listen stdio://`, lists recent threads, and reflects thread or turn state updates for watched threads.

## Run

```bash
swift run CodextensionMenubar
```

If the `codex` binary is not in the default app bundle path or `PATH`, set:

```bash
CODEX_BINARY=/absolute/path/to/codex swift run CodextensionMenubar
```

## Notes

- The current app-server request method for user input is `item/tool/requestUserInput`.
- Live `turn/*` and approval events still only come from the app-server instance this menu bar app launches.
- The menu bar refreshes Desktop activity every 1 second and refreshes the thread list every 5 seconds.
- For other recent Codex Desktop threads, the menu bar reads `~/.codex/state_*.sqlite` and combines two fallback signals:
- current Desktop app-server `turn/started` minus `turn/completed` count for the top-level `Running` icon
- very recent per-thread activity for row-level `Running` labels
- This clears `Running` much faster after a turn completes, but row-level status is still heuristic for threads this app did not resume itself.
- Click a thread row in the menu to open that thread in Codex Desktop.
- Hold `Option` while clicking a thread row to copy its thread id.

## Settings

- `Settings…` in the menu bar menu opens a persistent settings window.
- The window supports app language (`System`, `Korean`, `English`), a global menu toggle shortcut, launch at login, Sparkle update controls, and notification preferences.
- Closing the settings window does not terminate the app.
- `Launch at Login` and Sparkle updates are intentionally disabled when running with `swift run`; they are only active in the packaged `.app` build.

## Package App

Create a release-style `.app` bundle:

```bash
./scripts/package_app.sh
```

Optional environment variables:

```bash
APP_VERSION=42 \
APP_SHORT_VERSION=0.4.2 \
CODEXTENSION_BUNDLE_ID=com.example.codextension-menubar \
SPARKLE_FEED_URL=https://example.com/appcast.xml \
SPARKLE_PUBLIC_KEY=... \
APPLE_SIGN_IDENTITY="Developer ID Application: ..." \
./scripts/package_app.sh
```

This creates:

```text
dist/CodextensionMenubar.app
```

To notarize a signed app:

```bash
APPLE_NOTARY_PROFILE=your-notarytool-profile ./scripts/notarize_app.sh
```
