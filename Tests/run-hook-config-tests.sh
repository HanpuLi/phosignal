#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/phosignal-hook-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.codex" "$TMP/.claude"

cat > "$TMP/.codex/hooks.json" <<'JSON'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo keep-codex"}]}]}}
JSON
cat > "$TMP/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-claude"}]}]},"permissions":{"defaultMode":"auto"}}
JSON

HOOK="$TMP/PhoSignal/bin/phosignal-hook.py"
mkdir -p "${HOOK:h}"
cp "$ROOT/Integrations/phosignal-hook.py" "$HOOK"

HOME="$TMP" /usr/bin/python3 "$ROOT/scripts/configure-hooks.py" --install --hook-path "$HOOK"
HOME="$TMP" /usr/bin/python3 "$ROOT/scripts/configure-hooks.py" --install --hook-path "$HOOK"

HOME="$TMP" /usr/bin/python3 - <<'PY'
from pathlib import Path
import json, os
home=Path(os.environ['HOME'])
for path,keep in [(home/'.codex/hooks.json','keep-codex'),(home/'.claude/settings.json','keep-claude')]:
    d=json.load(open(path))
    commands=[]
    for entries in d.get('hooks',{}).values():
        for entry in entries:
            for hook in entry.get('hooks',[]): commands.append(hook.get('command',''))
    assert any(keep in c for c in commands), (path,'lost unrelated hook')
    ours=[c for c in commands if 'phosignal-hook.py' in c]
    assert ours, (path,'missing PhoSignal hook')
    for event, entries in d.get('hooks',{}).items():
        event_ours=[]
        for entry in entries:
            for hook in entry.get('hooks',[]):
                if 'phosignal-hook.py' in hook.get('command',''):
                    event_ours.append(hook.get('command',''))
        assert len(event_ours) <= 1, (path,event,'duplicate PhoSignal hook')
assert json.load(open(home/'.claude/settings.json'))['permissions']['defaultMode']=='auto'
PY

HOME="$TMP" /usr/bin/python3 "$ROOT/scripts/configure-hooks.py" --remove --hook-path "$HOOK"
HOME="$TMP" /usr/bin/python3 - <<'PY'
from pathlib import Path
import json, os
home=Path(os.environ['HOME'])
for path,keep in [(home/'.codex/hooks.json','keep-codex'),(home/'.claude/settings.json','keep-claude')]:
    d=json.load(open(path))
    commands=[]
    for entries in d.get('hooks',{}).values():
        for entry in entries:
            for hook in entry.get('hooks',[]): commands.append(hook.get('command',''))
    assert any(keep in c for c in commands), (path,'lost unrelated hook on remove')
    assert not any('phosignal-hook.py' in c for c in commands), (path,'PhoSignal hook not removed')
print('PASS hook config merge/remove')
PY
