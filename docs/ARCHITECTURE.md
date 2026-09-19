# Architecture

## Processes

**PhoSignal.app** is a menu-bar UI. It edits profiles, exposes diagnostics, requests Accessibility permission when asked, and supervises the bundled ChatGPT status watcher.

**phosignal daemon** owns hardware output. It reads the local state bus and profile store, then independently drives the keyboard and MagSafe channels.

**phosignal-hook.py** receives Codex/Claude lifecycle JSON on stdin and writes short-lived marker files.

**chatgpt-status-watch** reads ChatGPT's Accessibility status tree and writes the same state markers. It is launched as a child of the app so the user grants Accessibility to the app rather than to an unrelated global service.

**magsafe-led** is the only privileged component. It writes only AppleSMC `ACLC`.

## State

Default state directory:

`~/Library/Application Support/PhoSignal/`

Important entries:

- `profiles.json` — atomic profile store;
- `mode` — selected profile id;
- `active/` — source activity markers;
- `pulse` / `done` — one-shot event markers;
- `off`, `keyboard-off`, `magsafe-off` — output flags;
- `daemon.log`, `ui.log`, `chatgpt-watch.log` — diagnostics.

Environment variable `PHOSIGNAL_STATE_DIR` overrides the state root for tests and advanced setups.

## Persistence

`SignalProfiles.swift` is shared verbatim by app and daemon. It performs validation, revisioning and atomic JSON writes.

## Hardware safety

Keyboard acquisition records the user's last safe non-zero brightness and auto-brightness state. A suppressed/dimmed zero is never learned as the user's preferred level.

MagSafe patterns are sequences of named, fixed ACLC states. The hardware does not expose continuous LED brightness; breathe effects are timing/duty-cycle effects.

## Build and update safety

The daemon is executed directly by launchd. Install/update must `bootout` before replacing the executable and `bootstrap` afterwards because launchd may cache code-signing responsibility metadata for managed executables.

The build directory uses `phosignal-cli` for the CLI/daemon artifact and `PhoSignal` for the menu-bar executable. They must not differ only by case: the default macOS filesystem is case-insensitive and would otherwise allow one artifact to overwrite the other. The build script smoke-tests the CLI and rejects identical CLI/GUI artifacts.
