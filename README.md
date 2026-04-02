# CodexMate

> Codex keeps getting better, but human attention is still the bottleneck. CodexMate was built to reduce that bottleneck, so you can keep multiple projects moving without constantly checking, waiting, and context-switching.

CodexMate is a macOS menu bar companion for Codex Desktop. It helps you stay on top of recent threads, approvals, completions, and failures so your attention only returns when work actually needs you.

짧게 말하면, CodexMate는 AI가 아니라 인간의 주의력이 병목이 되는 순간을 줄이기 위한 Codex Desktop 메뉴바 동반 앱입니다.

## What CodexMate Does

CodexMate adds a lightweight layer on top of Codex Desktop. Instead of repeatedly checking windows and threads by hand, you can watch active work from the menu bar, catch important state changes, and jump back into the right thread when needed.

## See the Flow

![CodexMate menu bar thread list](docs/assets/readme/menubar-thread-list.png)
![CodexMate settings and notifications](docs/assets/readme/settings-notifications.png)

1. Watch recent Codex threads from the menu bar.
2. Catch approvals, completions, and failures without babysitting every window.
3. Jump back into the right thread when attention is actually needed.

## Download and Get Started

- Download the latest release archive: [GitHub Releases](https://github.com/gityeop/CodexMate/releases/latest)
- Requires `macOS 13+`
- Designed for people who already use Codex Desktop

1. Download the latest release archive from GitHub Releases.
2. Unzip the archive to reveal `CodexMate.app`.
3. Open `CodexMate.app` and keep it in the menu bar.
4. Return to Codex Desktop and let CodexMate surface the moments that need your attention.

## Key Features

- See recent Codex threads without keeping every project in the foreground.
- Spot running, waiting, and completed work faster from the menu bar.
- Notice approvals, completions, and failures without hovering over Codex Desktop all day.
- Re-open the exact thread that needs attention from the thread list.
- Adjust language, notifications, launch behavior, and update settings in one place.

## FAQ

### Who is this for?

CodexMate is for macOS users who already rely on Codex Desktop and want less manual checking while multiple threads or projects are in flight.

### Does it replace Codex Desktop?

No. CodexMate is a companion app. You still do the work in Codex Desktop.

### What does it require?

You need `macOS 13+` and a working Codex Desktop setup.

### Are all statuses exact?

Live turn and approval events come from the app-server instance that CodexMate launches. For other recent threads, some row-level status indicators use recent activity heuristics so you can still see what likely needs attention.

### Is there anything that only works in the packaged app?

Yes. `Launch at Login` and Sparkle updates are intentionally disabled when running with `swift run`; they are available in the packaged `.app`.

## For Developers

If you want to build CodexMate from source or work on packaging and release workflows, see:

- [Build from source](docs/build-from-source.md)
- [Packaging and release](docs/packaging-and-release.md)
