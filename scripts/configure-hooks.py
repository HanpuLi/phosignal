#!/usr/bin/env python3
"""Install/remove PhoSignal lifecycle hooks without clobbering other hooks."""

from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

HOME = Path.home()
CODEX = HOME / ".codex" / "hooks.json"
CLAUDE = HOME / ".claude" / "settings.json"

CODEX_EVENTS = [
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
    "PreCompact", "PostCompact", "SubagentStart", "SubagentStop",
    "Stop", "Interrupt", "SessionEnd",
]
CLAUDE_EVENTS = [
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
    "Stop", "SessionEnd", "Notification",
]

def load(path: Path) -> dict:
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path} does not contain a JSON object")
    return data

def atomic_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_name(path.name + f".bak-phosignal-{stamp}"))
    fd, temp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass

def command_entry(command: str) -> dict:
    return {"hooks": [{"type": "command", "command": command, "timeout": 3}]}

def contains_ours(entry: object) -> bool:
    if not isinstance(entry, dict):
        return False
    for hook in entry.get("hooks", []):
        if isinstance(hook, dict) and "phosignal-hook.py" in str(hook.get("command", "")):
            return True
    return False

def update(path: Path, source: str, events: list[str], hook_path: Path, install: bool) -> None:
    data = load(path)
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"{path}: hooks is not an object")
    command = f'/usr/bin/python3 "{hook_path}" --source {source}'
    for event in events:
        entries = hooks.get(event, [])
        if not isinstance(entries, list):
            raise ValueError(f"{path}: hooks.{event} is not an array")
        entries = [entry for entry in entries if not contains_ours(entry)]
        if install:
            entries.append(command_entry(command))
        if entries:
            hooks[event] = entries
        else:
            hooks.pop(event, None)
    atomic_json(path, data)
    print(("installed" if install else "removed"), source, "hooks in", path)

def main() -> int:
    ap = argparse.ArgumentParser()
    action = ap.add_mutually_exclusive_group(required=True)
    action.add_argument("--install", action="store_true")
    action.add_argument("--remove", action="store_true")
    ap.add_argument("--hook-path", type=Path, required=True)
    args = ap.parse_args()

    update(CODEX, "codex", CODEX_EVENTS, args.hook_path, args.install)
    update(CLAUDE, "claude", CLAUDE_EVENTS, args.hook_path, args.install)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
