# Privacy

PhoSignal is designed to work entirely on the local Mac.

## What is observed

- Codex and Claude Code lifecycle hook events such as prompt submitted, tool use, permission request and stop.
- ChatGPT Desktop accessibility **status labels** used to distinguish working / waiting / idle.
- Local battery / charging state for profile selection.

## What is stored

- small marker files representing active sources;
- profile settings and custom presets;
- daemon/UI diagnostic logs;
- a hashed session identifier for hook-originated active markers.

## What is not stored

- conversation transcripts;
- prompt text;
- tool arguments or tool output;
- account tokens or credentials.

The hook briefly reads the current hook payload in memory to classify lifecycle state and to suppress one known synthetic background task. It does not write prompt contents to disk.

## Network

The shipped app, daemon and integrations contain no telemetry or analytics and require no remote service.

## Accessibility

ChatGPT Desktop detection requires macOS Accessibility permission. The bundled watcher uses the Accessibility API to inspect application status elements; it does not use screenshots or OCR.
