# PhoSignal

[![CI](https://github.com/HanpuLi/phosignal/actions/workflows/ci.yml/badge.svg)](https://github.com/HanpuLi/phosignal/actions/workflows/ci.yml)
[![CodeQL](https://github.com/HanpuLi/phosignal/actions/workflows/codeql.yml/badge.svg)](https://github.com/HanpuLi/phosignal/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Turn the MacBook itself into a local status light for AI agents.

PhoSignal maps ChatGPT Desktop, Codex and Claude Code activity to two pieces of built-in hardware:

- the MacBook keyboard backlight, with smooth continuous brightness curves;
- the MagSafe connector LED, with green / amber / off / firmware flash states.

It is a native menu-bar app plus a small local daemon. There is no cloud service, account, telemetry or analytics.

> **Hardware / API note:** keyboard control uses Apple's private `CoreBrightness.KeyboardBrightnessClient` interface and MagSafe control uses the AppleSMC `ACLC` key. These are undocumented implementation details and can change in a macOS update. This project is intended for direct distribution / source builds, not the Mac App Store.

## What it does

- Six editable profiles: Smart, Focus, Agent-aware, Sprint, Quiet and Custom.
- Per-source MagSafe behaviour for ChatGPT, Codex, Claude Code, other agents and concurrent agents.
- Keyboard curves: smooth breathe, triangle, pulse and steady.
- Separate approval / completion feedback.
- Independent keyboard and MagSafe output toggles.
- Multiple custom presets with atomic persistence and hot reload.
- Source-aware previews that do not change the selected working profile.
- Built-in ChatGPT Desktop status watcher. The app requests Accessibility permission only when you press the permission button.
- Non-destructive Codex and Claude Code hook installation: existing hook entries are preserved.
- `doctor` diagnostics for keyboard, MagSafe helper, profiles and the daemon.

## Installation

Requirements:

- macOS 14 or later;
- a Mac with a supported built-in keyboard backlight and/or a MagSafe connector exposing `ACLC`;
- Xcode Command Line Tools when building from source;
- an administrator account for installing the narrowly scoped MagSafe helper.

Build and install:

```sh
./scripts/install.sh
```

The installer:

1. builds the app, daemon, hook and ACLC-only helper;
2. installs the app to `/Applications/PhoSignal.app`;
3. installs user binaries under `~/Library/Application Support/PhoSignal/bin/`;
4. installs one root-owned helper under `/Library/PrivilegedHelperTools/`;
5. installs a restricted `/etc/sudoers.d/phosignal` rule allowing only the helper's named LED commands;
6. installs the daemon and menu-bar LaunchAgents;
7. merges PhoSignal hooks into Codex and Claude Code JSON without deleting unrelated hooks;
8. verifies the daemon, helper and menu-bar process before reporting success.

After installation, open the menu-bar lightbulb. For ChatGPT Desktop, press **Accessibility…** once and grant the **current PhoSignal.app** in System Settings. Source builds are ad-hoc signed by default; rebuilding the app changes its code identity, so macOS may require you to remove/re-add or re-enable PhoSignal under Privacy & Security → Accessibility. A stable Developer ID-signed release does not have this source-build limitation.

Check the installation:

```sh
"$HOME/Library/Application Support/PhoSignal/bin/phosignal" doctor
```

## Uninstall

```sh
./scripts/uninstall.sh
```

By default settings and logs are preserved. To remove them too:

```sh
./scripts/uninstall.sh --purge
```

Uninstall returns the MagSafe LED to firmware control, unloads LaunchAgents, removes only PhoSignal hook entries, removes the helper/sudoers rule, and leaves unrelated Codex/Claude hooks intact.

## Architecture

```text
Codex hooks ───────┐
Claude hooks ──────┼──> Application Support/PhoSignal state bus
ChatGPT AX watcher ┘                 │
                                     ▼
                              phosignal daemon
                               │                 │
                         CoreBrightness       ACLC helper
                               │                 │
                         keyboard light       MagSafe LED
```

Profile schema and defaults live in `Sources/SignalProfiles.swift` and are shared by the app and daemon. See [Architecture](docs/ARCHITECTURE.md) for the state machine, persistence model and privilege boundary.

## Privacy

PhoSignal is local-only. It contains no networking code in the app, daemon or lifecycle hook. Hook payloads are used only to derive lifecycle state; prompts are not stored. The ChatGPT watcher inspects accessibility status labels, not conversation text. See [PRIVACY.md](PRIVACY.md).

## Security

The root helper can address **only** the `ACLC` key and exposes a fixed command set. The installer does not grant general passwordless sudo. See [SECURITY.md](SECURITY.md).

## Compatibility

Keyboard and MagSafe are independent channels. If `KeyboardBrightnessClient` is unavailable, the daemon can continue in MagSafe-only mode. If the `ACLC` helper is unavailable, keyboard signalling still works.

## Development

```sh
./Tests/run-profile-store-tests.sh
./Tests/run-hook-config-tests.sh
./Tests/run-hook-behaviour-tests.sh
./scripts/build.sh
```

CI builds all native components on macOS and runs persistence / hook-merge tests without touching real hardware.

## Project history and name

PhoSignal grew from a personal prototype called Agent Glow. The public project was renamed before release because another open-source AI-agent lighting project already uses `AgentGlow`. This repository is an independent implementation.

## License

MIT. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and [docs/PROVENANCE.md](docs/PROVENANCE.md).
