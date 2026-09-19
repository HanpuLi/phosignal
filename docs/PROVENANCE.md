# Provenance and clean-room notes

This file records the source-provenance review performed before the first public release. It is an engineering record, not a legal opinion.

## Original project

The codebase began as a local macOS utility built specifically around a MacBook keyboard backlight, the MagSafe LED, and local AI-agent lifecycle signals. The public tree was split from that private prototype before release and renamed **PhoSignal**.

## CoreBrightness

`Sources/phosignald.swift` resolves `KeyboardBrightnessClient` and Objective-C selectors dynamically. The private selector names are discoverable runtime/API facts. During open-source preparation the implementation was compared against `noluyorAbi/macos-keyboard-backlight` (MIT), which uses JavaScript/koffi rather than this Swift implementation. The audit found no non-trivial identical lines.

## AppleSMC / ACLC

`Helpers/magsafe-led.c` is an independent minimal AppleSMC client restricted to the `ACLC` key. During open-source preparation it was compared against `kamenlevi/MagHue` (GPL-3.0). The implementations differ in language and structure; the audit found no suspicious identical non-trivial lines. GPL-licensed MagHue source is neither copied nor linked.

The numeric ACLC states used by the helper were independently verified on real hardware during development: firmware/system `0x00`, off `0x01`, green `0x03`, amber `0x04`; firmware accepts `0x06`/`0x07` as amber flash states on the tested machine.

## Agent integrations

Codex/Claude hooks write only lifecycle markers to a local state directory. The ChatGPT watcher is a standalone Accessibility-tree scanner written for this project. It does not use OCR and does not persist conversation text.

## Name collision review

The prototype name `Agent Glow` was retired after finding an existing `shuhari04/AgentGlow` project in the same AI-agent lighting space. Candidate public names were checked against GitHub/Homebrew/package indexes before choosing `PhoSignal`.

## Reproducible review

Before release, the repository should continue to pass:

- exact/non-trivial line-overlap checks against referenced upstream projects;
- secret scanning;
- native compilation with warnings enabled;
- isolated profile-store and hook-merge tests.
