#!/usr/bin/env python3
"""Agent lifecycle hook -> PhoSignal state bus."""
from __future__ import annotations
import argparse, hashlib, json, os, sys, time
from pathlib import Path

DEFAULT_STATE = Path.home() / "Library" / "Application Support" / "PhoSignal"
INTERNAL_PROMPT_MARKERS = (
    "generate 0 to 3 hyperpersonalized suggestions for what this user can do with codex in this local project",
)

def norm_event(value):
    return "".join(ch for ch in str(value or "").lower() if ch.isalnum())

def session_key(source, payload):
    sid = (payload.get("session_id") or payload.get("thread_id") or
           payload.get("agent_id") or payload.get("conversation_id") or
           f"ppid-{os.getppid()}")
    digest = hashlib.sha256(f"{source}:{sid}".encode("utf-8", "replace")).hexdigest()[:16]
    safe_source = "".join(ch if ch.isalnum() else "_" for ch in source)[:20] or "agent"
    return f"{safe_source}-{digest}"

def prompt_text(payload):
    p = payload.get("prompt", "")
    if isinstance(p, str):
        return p
    if isinstance(p, list):
        out = []
        for item in p:
            if isinstance(item, str):
                out.append(item)
            elif isinstance(item, dict):
                for k in ("text", "content", "input_text"):
                    if isinstance(item.get(k), str):
                        out.append(item[k])
        return "\n".join(out)
    return str(p or "")

def is_internal_background(payload):
    text = prompt_text(payload).lower()
    return any(marker in text for marker in INTERNAL_PROMPT_MARKERS)

def touch(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(exist_ok=True)

def remove(path):
    try: path.unlink()
    except FileNotFoundError: pass

def cleanup_old(directory, max_age=86400.0):
    now = time.time()
    try:
        for p in directory.iterdir():
            try:
                if p.is_file() and now - p.stat().st_mtime > max_age:
                    p.unlink()
            except OSError:
                pass
    except OSError:
        pass

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--source", default="codex")
    args, _ = ap.parse_known_args()
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict): payload = {}
    except Exception:
        payload = {}

    state = Path(os.environ.get("PHOSIGNAL_STATE_DIR", str(DEFAULT_STATE))).expanduser()
    active_dir, ignored_dir = state / "active", state / "ignored"
    active_dir.mkdir(parents=True, exist_ok=True)
    ignored_dir.mkdir(parents=True, exist_ok=True)
    cleanup_old(ignored_dir)

    key = session_key(args.source, payload)
    active, ignored = active_dir / key, ignored_dir / key
    event = norm_event(payload.get("hook_event_name") or payload.get("hookEventName") or payload.get("event"))

    if event == "userpromptsubmit" and is_internal_background(payload):
        remove(active); touch(ignored); return 0

    if ignored.exists():
        if event in {"stop", "interrupt", "sessionend"}:
            remove(active); remove(ignored)
        else:
            touch(ignored)
        return 0

    if event == "userpromptsubmit":
        touch(active)
    elif event in {"pretooluse", "posttooluse", "precompact", "postcompact", "subagentstart", "subagentstop"}:
        touch(active)
    elif event == "permissionrequest":
        touch(active); touch(state / "pulse")
    elif event == "notification":
        notification_type = norm_event(payload.get("notification_type") or payload.get("notificationType"))
        if notification_type == "permissionprompt" or "permission_prompt" in raw.lower():
            touch(state / "pulse")
    elif event == "stop":
        remove(active)
        # Flash completion only when this was the last active source.
        # ChatGPT Desktop can represent one task both via UI status and Codex hooks.
        try:
            aggregate_idle = not any(p.is_file() for p in active_dir.iterdir())
        except OSError:
            aggregate_idle = True
        if aggregate_idle:
            touch(state / "done")
    elif event in {"interrupt", "sessionend"}:
        remove(active); remove(ignored)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
