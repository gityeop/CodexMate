# CodextensionMenubar

Small macOS menu bar app that launches `codex app-server --listen stdio://`, shows a menu bar icon badge for actionable work, and opens a monochrome project panel with recent threads.

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
- Left click the menu bar icon to toggle the floating project panel.
- Right click the menu bar icon to open the utility menu with refresh, debug log copy, and quit actions.
- The menu bar refreshes Desktop activity every 1 second and refreshes the thread list every 2 seconds.
- The numeric badge counts current actionable threads only: waiting for user input and approval-required threads.
- For other recent Codex Desktop threads, the app reads `~/.codex/state_*.sqlite` to infer active work. This is still heuristic for threads this app did not resume itself.
- Click a thread row in the panel to open that thread in Codex Desktop.
- Hold `Option` while clicking a thread row to copy its thread id.
