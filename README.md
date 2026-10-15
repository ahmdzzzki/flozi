# Flozi

A little company while AI works. A native macOS notch companion with one tiny lavender friend, 3D-rendered expressions, and a spring animation when your cursor approaches the notch.

## Flozi 0.2

- **One Flozi:** an original lavender cloud-ghost with a transparent 3D-rendered sprite atlas. Fourteen expressions, an idle blink, and an alternate thinking pose. Lightweight floating, breathing, and gaze tilt animations. These are rendered sprites, not a real-time 3D mesh.
- **Hover to reveal:** the notch expands with a spring, then closes 300 ms after the cursor leaves. Click the header or pin button to hold it open. Transparent areas pass mouse clicks through to the app underneath. The camera cutout stays reserved.
- **Modes:** idle, thinking, working, reading, searching, coding, testing, waiting for you, success, needs attention, interrupted, sleeping, disconnected, and uncertain.
- **Live vs preview:** Try a mood previews every expression, clearly labelled. The session list continues showing real data. Back to live restores the automatic avatar.
- **Original soft sounds:** locally synthesized cues for start, completion, waiting, and attention. Mute, volume, and individual sound previews. Muted on a fresh install; existing sound preferences are preserved.
- Up to three recent local Codex sessions, with an active count and elapsed time. The avatar prioritizes an active task over another task’s celebration, and prioritizes attention/waiting over routine work.
- Reduced Motion respects the macOS setting: no floating, spinning, gaze tilt, frame cycling, or spring movement.

## Build and run

Requires macOS 14+ and a Swift 6 toolchain.

```sh
swift test
bash scripts/build-app.sh
open dist/Flozi.app
```

Move your cursor to the top-center notch to open Flozi. The sparkles menu bar item also opens it. Click the pin to keep it expanded; unpin and move away to collapse. Use Try a mood for all expressions, and Sounds to hear the four audio cues.

The build script embeds the SwiftPM resource bundle inside the app. The app can be moved without keeping the build folder beside it. It is locally ad-hoc signed, not notarized for distribution.

## Status source and limits

Flozi experimentally reads **local Codex JSONL rollout logs**, under `$CODEX_HOME/sessions` or `~/.codex/sessions`. It polls every 1.5 seconds and follows up to 200 most recently modified session files. Startup reads the last 512 KiB per file plus a bounded metadata header. Older events may be unavailable. It does not attach to or control Codex app-server.

Modes describe **last observed activity**, not guaranteed real-time process state:

| Mode | Observed signal |
| --- | --- |
| Thinking | A reasoning item; no reasoning text is displayed or retained |
| Working | Turn start, agent message, or a generic tool |
| Reading / searching / coding / testing | Tool names or command verbs; completed item records can arrive after the action |
| Waiting | An observed user-input request or question item; not a guarantee of pending approval |
| Success / interrupted | A matching turn completion / abort event |
| Needs attention | A failed command or file-change item, or an explicit failed task event |
| Idle / sleeping | No known active turn; sleep after 90 seconds of inactivity |
| Disconnected | Local session folder cannot be read |
| Uncertain | A known active turn has no fresh event for ten minutes |

A failed tool does not mark the whole turn finished; subsequent events can recover it. Late events from an older turn cannot complete the new turn. Sound cues only follow newly observed transitions; old startup history does not play completion sounds.

The log format is not a stable public API. Remote/cloud tasks, ChatGPT, detailed approval state, and individual background terminal processes are **not monitored**. Flozi cannot promise coverage of all Codex activity. Elapsed time is time since the last observed start, not a progress percentage. A stale active session remains uncertain even if the avatar previews a different expression.

The application makes no network requests or uploads. Only event types, coarse activity, timestamps, session IDs, and project folder names are kept in memory. Prompts, output, tool arguments, command text, and reasoning text are not retained or displayed. No API key, Accessibility access, screen recording, or global event tap is needed. No launch-at-login or permission changes are enabled automatically.

ChatGPT support is deferred until a viable status integration is verified. A separate app-server process cannot automatically observe an existing Codex desktop runtime. See the [official app-server protocol](https://learn.chatgpt.com/docs/app-server) for that separate integration surface.

## Assets and development

`FloziCore` contains the incremental log reader, lifecycle reducer, and mode resolver. Tests cover partial writes, truncation, malformed records, late events, failed-tool recovery, stale sessions, concurrent tasks, and celebration/sleep timing.

The built-in ImageGen generated `Sources/Flozi/Resources/flozi-atlas.png`; its prompt is in [docs/avatar-generation.md](docs/avatar-generation.md). Sound files are original local sine-wave synthesis. Avatar motion and window interactions are native SwiftUI/AppKit.
