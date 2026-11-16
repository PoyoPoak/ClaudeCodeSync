#!/usr/bin/env bash
# On-demand health check for the config sync. Run through /verify-config-sync. No hook calls this.
# Read-only: never commits, pulls, pushes, or edits files. `git fetch` updates remote-tracking refs only.
# Usage: verify-config-sync.sh [--test]    --test also runs the offline test suite.
# Exit status is non-zero if any check reports FAIL.
set -uo pipefail

REPO="$HOME/.claude"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

pass() { echo "PASS $*"; }
warn() { echo "WARN $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- Repo ---
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  fail "~/.claude is not a git repo"
  exit 1
fi
cd "$REPO" || exit 1
pass "~/.claude is a git repo"

origin="$(git remote get-url origin 2>/dev/null)"
if [ -n "$origin" ]; then pass "origin is $origin"; else fail "no origin remote, sync has nowhere to push"; fi

# Name origin explicitly: without an argument, gh prefers a remote called upstream (README.md adds one).
visibility="$([ -n "$origin" ] && gh repo view "$origin" --json visibility --jq .visibility 2>/dev/null)"
case "$visibility" in
  PRIVATE) pass "GitHub repo is private" ;;
  "") warn "could not read repo visibility (not on GitHub, or gh is missing or logged out). Make sure the repo is private" ;;
  *) fail "GitHub repo visibility is $visibility, expected PRIVATE" ;;
esac

# --- Sync state ---
echo "INFO $(bash "$SCRIPTS/config-sync.sh" --status)"
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' GIT_TERMINAL_PROMPT=0
if timeout 15 git fetch --quiet 2>/dev/null; then pass "remote is reachable"; else warn "could not fetch, counts below may be stale"; fi

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  fail "rebase in progress, sync is paused until it is resolved"
fi

read -r behind ahead < <(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo "? ?")
if [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
  pass "in step with remote"
else
  warn "behind remote by $behind, ahead by $ahead (next sync fixes this)"
fi

# settings.json differs from the commit on every device by its per-device keys (KEYS in config-sync.sh).
# Count it only when something else in it changed.
changed="$(git status --porcelain | grep -cv ' settings\.json$')"
if [ -n "$(git status --porcelain -- settings.json)" ] && ! python3 - "$SCRIPTS/config-sync.sh" <<'EOF' 2>/dev/null; then
import ast, json, re, subprocess, sys
keys = ast.literal_eval(re.search(r"KEYS = (\(.*?\))", open(sys.argv[1]).read()).group(1))
head = subprocess.run(["git", "show", "HEAD:settings.json"], capture_output=True, text=True)
committed = json.loads(head.stdout) if head.returncode == 0 else {}
local = json.load(open("settings.json"))
strip = lambda d: {k: v for k, v in d.items() if k not in keys}
sys.exit(0 if strip(committed) == strip(local) else 1)
EOF
  changed=$((changed + 1))
fi
if [ "$changed" -eq 0 ]; then pass "no uncommitted changes"; else warn "$changed uncommitted change(s) (next sync commits these)"; fi

echo "INFO last sync per device:"
git log --format=%s --grep='^sync: ' -n 500 | awk '$1 == "sync:" && !seen[$2]++ { print "INFO   " $2 " " $3 }'

# --- Privacy ---
forbidden="$(git ls-files | grep -E '^(\.credentials\.json|mcp\.json|history\.jsonl|\.sync\.log|projects/|agent-memory/|plugins/|plans/|sessions/|jobs/|daemon/|backups/|skills/synced/)')"
if [ -z "$forbidden" ]; then pass "no private paths tracked"; else fail "private paths tracked: $(tr '\n' ' ' <<<"$forbidden")"; fi

if [ ! -f scripts/token-patterns.txt ]; then
  fail "scripts/token-patterns.txt is missing, token scan cannot run"
else
  matches="$(git grep -I -l -E -f scripts/token-patterns.txt HEAD -- 2>/dev/null)"
  if [ -z "$matches" ]; then pass "no token patterns in tracked files"; else fail "possible tokens in: $(tr '\n' ' ' <<<"$matches")"; fi
fi

# --- Hooks ---
hook_report="$(python3 - <<'EOF'
import json
try:
    d = json.load(open("settings.json"))
except Exception as e:
    print(f"FAIL settings.json is not valid JSON: {type(e).__name__}")
    raise SystemExit
print("PASS settings.json is valid JSON")
expected = {"SessionStart": "^startup$", "SessionEnd": "^(prompt_input_exit|logout|other)$"}
for event, matcher in expected.items():
    found = [
        g.get("matcher") for g in d.get("hooks", {}).get(event, [])
        if any("config-sync.sh" in h.get("command", "") for h in g.get("hooks", []))
    ]
    if found == [matcher]:
        print(f"PASS {event} sync hook present with matcher {matcher}")
    elif found:
        print(f"FAIL {event} sync hook matcher is {found}, expected {matcher}")
    else:
        print(f"FAIL {event} sync hook is missing")
EOF
)"
echo "$hook_report"
fails=$((fails + $(grep -c '^FAIL' <<<"$hook_report")))

# --- Links ---
if [ -f dotconfig/links.txt ]; then
  while read -r rel; do
    case "$rel" in "" | "#"*) continue ;; esac
    link="$HOME/.config/$rel"
    target="$REPO/dotconfig/$rel"
    if [ ! -L "$link" ]; then
      fail "~/.config/$rel is not a symlink, so changes do not sync. Run scripts/install.sh"
    elif [ ! -e "$link" ] || [ "$(readlink -f "$link")" != "$(readlink -f "$target")" ]; then
      fail "~/.config/$rel does not resolve to dotconfig/$rel"
    else
      pass "~/.config/$rel links into the repo"
    fi
  done <dotconfig/links.txt
else
  warn "dotconfig/links.txt is missing"
fi

# --- Device readiness ---
# A path like /home/<name>/... in settings.json works only where the home is the same. Prefer "$HOME/...".
others="$(grep -oE '/(home|Users)/[^/"[:space:]]+' settings.json 2>/dev/null | sort -u | grep -vx "$HOME" | tr '\n' ' ')"
if [ -n "$others" ]; then
  warn "settings.json has absolute paths outside $HOME: ${others% }. Use \$HOME in commands so they work on every device"
fi

# Windows tools (Fork, editors) writing over \\wsl$ drop exec bits. With fileMode on, git reports each as a change.
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  if [ "$(git config --bool core.fileMode)" = "false" ]; then
    pass "core.fileMode is false"
  else
    warn "core.fileMode is not false, Windows tools will show mode-only changes. Run scripts/install.sh"
  fi
fi

# scripts/tools.txt lists the CLIs this config needs, one "<command> <install hint>" per line.
if [ -f scripts/tools.txt ]; then
  while read -r tool hint; do
    case "$tool" in "" | "#"*) continue ;; esac
    command -v "$tool" >/dev/null || warn "$tool is not on PATH: $hint"
  done <scripts/tools.txt
fi

python3 - <<'EOF' || true
import json, os
plugins = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try:
    enabled = [k for k, v in json.load(open("settings.json")).get("enabledPlugins", {}).items() if v and not k.endswith("@builtin")]
    try:
        data = json.load(open(plugins))
        installed = set(data.get("plugins", data))
    except OSError:
        installed = set()
    missing = sorted(set(enabled) - installed)
    print(f"WARN enabled plugins not installed: {', '.join(missing)}. Run scripts/install.sh --plugins" if missing else "PASS all enabled plugins are installed")
except Exception as e:
    print(f"WARN could not compare plugins: {type(e).__name__}")
EOF

# --- Guard activity ---
if [ -f .sync.log ]; then
  last_ok="$(grep ' ok: ' .sync.log | tail -1)"
  if [ -n "$last_ok" ]; then echo "INFO last successful sync: $last_ok"; else warn "no successful sync in .sync.log"; fi
  echo "INFO skip reasons in .sync.log:"
  grep -E ' skip: ' .sync.log | sed -E 's/^[^ ]+ skip: /INFO   /' | sort | uniq -c | sort -rn | head -5
  echo "INFO recent warnings:"
  grep ' WARN ' .sync.log | tail -3 | sed 's/^/INFO   /'
else
  warn "no .sync.log yet, no sync has run on this device"
fi

# --- Optional test suite ---
if [ "${1:-}" = "--test" ]; then
  out="$(mktemp)"
  if bash "$SCRIPTS/test-config-sync.sh" >"$out" 2>&1; then
    pass "test suite: $(tail -1 "$out")"
  else
    fail "test suite failed:"
    grep '^FAIL' "$out"
  fi
  rm -f "$out"
fi

echo
if [ "$fails" -eq 0 ]; then echo "Result: no failures"; else echo "Result: $fails failure(s)"; fi
[ "$fails" -eq 0 ]
