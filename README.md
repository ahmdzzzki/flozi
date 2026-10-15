# Flozi

A little company while AI works. Flozi is a native macOS notch companion that shows recent local Codex activity above your other windows.

## First prototype

- A compact notch with an active-session count; hover to expand and click to pin.
- Shows up to three recent sessions, project folder names, last known activity, and elapsed time.
- Four selectable, animated native vector avatars: robot, cat, ghost, and capybara. No avatar is chosen on first launch. These are prototype drawings; the final illustrated mascot is still to be selected.
- Optional completion sound, volume slider, mute, and a Listen button. Uses macOS built-in sounds for this prototype; custom audio is still to be selected.
- Clearly labelled Preview mode, separate from live activity.
- Menu bar access and Quit. No Dock icon.

## Build and run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
swift test
bash scripts/build-app.sh
open dist/Flozi.app
```

Hover over the top-center notch to choose an avatar. The sparkles menu bar item can reopen Flozi. Click the pin to keep it expanded. Sound starts muted; use Listen to preview it, then enable it with the speaker button.

## What it can observe

This version **experimentally reads local Codex JSONL rollout logs**, under `$CODEX_HOME/sessions` or `~/.codex/sessions`. It polls every two seconds and follows up to 200 most recently modified session files. Startup reads at most the last 512 KiB per file plus its metadata header; older events may be unavailable. It does not attach to or control the Codex app-server.

`task_started`, tool-call records, `task_complete`, and `turn_aborted` are mapped to coarse activity states. Flozi does not show private thinking text, prompts, output, or tool arguments. It extracts only event types, timestamps, session IDs, and project folder names into memory. No API key, network request, account connection, or upload is needed by the app.

The local log format is not a stable public integration API. Sessions that do not write these records, remote/cloud tasks, ChatGPT, detailed approval state, and individual background terminal processes are **not monitored**. Flozi cannot guarantee coverage of all Codex activity. A running state with no event in ten minutes is shown as “Last seen working” and excluded from the recent active count; this is uncertainty, not a claim that a long task stopped. Elapsed time is time since the last observed start, not a progress percentage. Startup history does not trigger completion sounds.

ChatGPT support is planned after a viable status integration is verified. A separate app-server process cannot automatically observe the runtime of an existing Codex desktop instance. The [official app-server protocol](https://learn.chatgpt.com/docs/app-server) is a future adapter option only when the relevant runtime connection is available.

## Current limits

- Tracks the primary display. Actual camera cutout width is reserved when macOS exposes its geometry; other displays get a floating notch.
- App bundle is locally ad-hoc signed, not notarized for distribution.
- No launch-at-login or permission changes are enabled automatically.
- Final app icon, illustrated animation assets, and custom sound design remain user choices.

## Development

`FloziCore` contains the incremental log reader and lifecycle reducer. Tests cover out-of-order completion, tool events, malformed lines, partial writes, truncation, and missing folders.
