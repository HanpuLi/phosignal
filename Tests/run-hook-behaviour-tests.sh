#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$(mktemp -d /tmp/phosignal-hook-behaviour.XXXXXX)"
trap 'rm -rf "$STATE"' EXIT
HOOK="$ROOT/Integrations/phosignal-hook.py"

emit() {
  local source="$1" json="$2"
  printf "%s" "$json" | PHOSIGNAL_STATE_DIR="$STATE" /usr/bin/python3 "$HOOK" --source "$source"
}

SECRET_PROMPT="PRIVATE_PROMPT_SHOULD_NEVER_BE_STORED_8f234bc1"
emit codex "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"$SECRET_PROMPT\"}"
[[ "$(find "$STATE/active" -type f | wc -l | tr -d " ")" == "1" ]]
! rg -l "$SECRET_PROMPT" "$STATE" >/dev/null 2>&1

emit codex "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s1\"}"
[[ -f "$STATE/pulse" ]]
rm -f "$STATE/pulse"

# A second source keeps the aggregate active; stopping s1 must not signal done.
emit claude "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s2\",\"prompt\":\"hello\"}"
[[ "$(find "$STATE/active" -type f | wc -l | tr -d " ")" == "2" ]]
emit codex "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\"}"
[[ ! -f "$STATE/done" ]]
emit claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"s2\"}"
[[ -f "$STATE/done" ]]
rm -f "$STATE/done"

# The known synthetic Codex suggestion prompt is quarantined, not treated as user activity.
emit codex "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"synthetic\",\"prompt\":\"Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project\"}"
[[ "$(find "$STATE/active" -type f | wc -l | tr -d " ")" == "0" ]]
[[ "$(find "$STATE/ignored" -type f | wc -l | tr -d " ")" == "1" ]]
emit codex "{\"hook_event_name\":\"Stop\",\"session_id\":\"synthetic\"}"
[[ "$(find "$STATE/ignored" -type f | wc -l | tr -d " ")" == "0" ]]
[[ ! -f "$STATE/done" ]]

echo "PASS lifecycle hook behaviour/privacy"
