# Build CodexMate from Source

CodexMate can be built and launched as a local app bundle when developing or validating behavior.

## Requirements

- `macOS 13+`
- Xcode 26 or later, including Swift and the Icon Composer asset compiler
- A working `codex` binary available in the default app bundle path or in `PATH`
- A GUI login session when testing the app UI

## Run from Source

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./script/build_and_run.sh
```

This stops the running CodexMate process, builds a debug app at `dist/dev/CodexMate.app`, and opens it. The Codex Run action uses the same script. To reopen the existing build, use `open dist/dev/CodexMate.app`.

CodexMate now opens a resizable Git Graph window and appears in the Dock. Closing the window keeps the menu bar or notch active. Reopen it from the Dock, **Window → Open Git Graph**, Command-1, or the menu bar/notch dropdown.

The window reads local Git repositories from the Codex project catalog. It displays all registered worktrees, local/remote branches, and up to 200 recent commits, including detached worktree HEADs. Select a worktree to inspect uncommitted files and recent linked Codex chats. Git refreshes every 10 seconds while the window is visible and stops when it closes or minimizes. Command-R refreshes manually. Git failures are displayed with the actual command error.

Projects without Git show a neutral explanation instead of a repository error. Their project folder and linked Codex chats remain available. The sidebar always reserves the same areas for projects and worktrees, with an empty-state message when a project does not use Git; Git-only file changes are hidden. Missing paths and other Git failures still display their actual errors.

If the `codex` binary is not in the default app bundle path or `PATH`, set:

```bash
CODEX_BINARY=/absolute/path/to/codex ./script/build_and_run.sh
```

## VM or UTM Troubleshooting

If you are running inside UTM or another VM, launch the bundled app in a GUI login session. To open Settings on startup:

```bash
open dist/dev/CodexMate.app --args --open-settings-on-launch
```

Normal launches appear in the Dock and app switcher. The Settings launch argument opens Settings in addition to the main window.

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

- The app icon source is `Packaging/CodexMate.icon`. Its 1024 × 1024 artwork fills the canvas completely; macOS supplies the rounded mask. Keep the artwork at 100% scale without transparent outer margins or a second rounded tile.
- Packaging compiles the Icon Composer document with `actool` and merges its icon metadata into `Info.plist`. `Packaging/CodexMate.png` is an exported preview, not the build input.
- The current app-server request method for user input is `item/tool/requestUserInput`.
- Live `turn/*` and approval events only come from the app-server instance the menu bar app launches.
- The menu bar uses a state-dependent refresh policy:
  - when the menu is open, Desktop activity refreshes as fast as 1 second and the thread list refreshes every 5 seconds
  - when no recent threads exist, Desktop activity stays at the slower 5 second cadence while the thread list remains on the 5 second menu cadence
  - when the app is tracking recent threads and the overall status is running, Desktop activity stays at 1 second and the thread list moves to 15 seconds
  - when recent threads exist but the app is otherwise idle, Desktop activity stays at 5 seconds and the thread list moves to 60 seconds
- See `Sources/CodexMate/RefreshSchedulingPolicy.swift` for the exact refresh policy.
- For other recent Codex Desktop threads, the menu bar typically reads `~/.codex/state_*.sqlite` and combines two state signals:
  - current Desktop app-server `turn/started` minus `turn/completed` count for the top-level `Running` icon
  - very recent per-thread activity for row-level `Running` labels
- This clears `Running` much faster after a turn completes, but row-level status is still heuristic for threads the app did not resume itself.
- Click a thread row in the menu to open that thread in Codex Desktop.
- Hold `Option` while clicking a thread row to copy its thread id.
- `Launch at Login` and Sparkle updates are intentionally disabled when running with `swift run`; they are only active in the packaged `.app` build.
