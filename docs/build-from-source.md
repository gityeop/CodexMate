# Build CodexMate from Source

CodexMate can be run directly from source when you are developing or validating behavior locally.

## Requirements

- `macOS 13+`
- A Swift/Xcode toolchain that can run `swift build` and `swift run`
- A working `codex` binary available in the default app bundle path or in `PATH`
- A GUI login session when testing the app UI

## Run from Source

```bash
swift run CodexMate
```

If the `codex` binary is not in the default app bundle path or `PATH`, set:

```bash
CODEX_BINARY=/absolute/path/to/codex swift run CodexMate
```

## VM or UTM Troubleshooting

If you are running inside UTM or another VM and the app seems to not launch, force a normal app window on startup:

```bash
CODEXMATE_REGULAR_APP=1 \
CODEXMATE_OPEN_SETTINGS_ON_LAUNCH=1 \
CODEX_BINARY=/absolute/path/to/codex \
swift run CodexMate
```

This disables the accessory-only launch style for that run so the app appears in the Dock and app switcher and immediately opens Settings.

For the packaged `.app`, you can do the same with launch arguments:

```bash
open -a /absolute/path/to/CodexMate.app --args --regular-app --open-settings-on-launch
```

Additional notes:

- Run the app from a GUI login session inside the VM, not over SSH or another headless shell.
- If the menu bar item is hard to spot in the VM, use `CODEXMATE_REGULAR_APP=1` and `CODEXMATE_OPEN_SETTINGS_ON_LAUNCH=1`.
- The packaged `.app` opens `Settings` automatically on first launch so you still get a visible window even if the menu bar item is not obvious.
- If CodexMate starts but cannot connect, point `CODEX_BINARY` at a working `codex` binary inside the guest.
- Startup debug logs are written to `~/Library/Logs/CodexMate/overlay-debug.log`.

## Notes for Developers

- The current app-server request method for user input is `item/tool/requestUserInput`.
- Live `turn/*` and approval events only come from the app-server instance the menu bar app launches.
- The menu bar uses a state-dependent refresh policy:
  - when the menu is open, Desktop activity refreshes as fast as 1 second and the thread list refreshes every 5 seconds
  - when no recent threads exist, Desktop activity stays at the slower 5 second cadence while the thread list remains on the 5 second menu cadence
  - when the app is tracking recent threads and the overall status is running, Desktop activity stays at 1 second and the thread list moves to 15 seconds
  - when recent threads exist but the app is otherwise idle, Desktop activity stays at 5 seconds and the thread list moves to 60 seconds
- See `Sources/CodexMate/RefreshSchedulingPolicy.swift` for the exact refresh policy.
- For other recent Codex Desktop threads, the menu bar reads `~/.codex/state_*.sqlite` and combines two fallback signals:
  - current Desktop app-server `turn/started` minus `turn/completed` count for the top-level `Running` icon
  - very recent per-thread activity for row-level `Running` labels
- This clears `Running` much faster after a turn completes, but row-level status is still heuristic for threads the app did not resume itself.
- Click a thread row in the menu to open that thread in Codex Desktop.
- Hold `Option` while clicking a thread row to copy its thread id.
- `Launch at Login` and Sparkle updates are intentionally disabled when running with `swift run`; they are only active in the packaged `.app` build.
