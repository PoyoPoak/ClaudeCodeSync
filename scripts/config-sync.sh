#!/usr/bin/env bash
# Sync ~/.claude with its private git remote.
#
# Usage: see usage() below, or run config-sync.sh --help.
#
# The mode is per device, stored in ~/.claude/.sync-mode, which git ignores. A pull can never change it.
# With no file, the mode is manual. In manual mode the hooks do nothing.
#
# In auto mode, hooks sync only for a Claude Code window the user opened. Measured on Claude Code 2.1.318:
#   window opened by user     SESSION_ATTENDED=1, no CHILD_SESSION on the Claude process
#   claude -p, claude --bg    SESSION_ATTENDED=0
#   window opened by Claude   SESSION_ATTENDED=1, CHILD_SESSION=1 on the Claude process
#   subagent                  does not fire these events; agent_id is checked as a second layer
# CLAUDE_CODE_SESSION_ATTENDED and CLAUDE_PID are not documented, so anything unexpected skips and logs a reason.
# If a Claude Code update changes them, auto sync stops and .sync.log says why. /verify-config-sync reports this.
# The guard reads /proc, so where there is none (macOS), auto mode skips every run and logs why. Sync manually there.
#
# Hook runs never block a session: every path exits 0, and warnings print on SessionStart, where Claude sees them.
# A --now run prints its result and exits 1 on failure.
set -uo pipefail

REPO="$HOME/.claude"
PATTERNS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token-patterns.txt"
LOG="$REPO/.sync.log"
MODE_FILE="$REPO/.sync-mode"
event=""
action=sync
agent_id="-"

current_mode() {
  if [ "$(cat "$MODE_FILE" 2>/dev/null)" = "auto" ]; then echo auto; else echo manual; fi
}
usage() {
  cat <<'EOF'
usage: config-sync.sh [option]
  --now              sync now, whatever the mode
  --overwrite        make the remote match this device, replacing other devices' changes
  --reset            make this device match the remote, saving its discarded work on a local branch
  --mode auto|manual choose how this device syncs
  --status           show the mode for this device
  --help             show this help
  (no option)        hook entry point, reads hook input from stdin
EOF
}
log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
warn() {
  log "WARN $*"
  if [ "$event" = "SessionStart" ] || [ "$event" = "Manual" ]; then echo "config-sync: $*"; fi
}
stop() {
  if [ "$event" = "Manual" ]; then exit 1; fi
  exit 0
}

skip_reason() {
  [ -n "$event" ] || { echo "unparsable hook input"; return; }
  [ "$agent_id" = "-" ] || { echo "subagent"; return; }
  [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "1" ] || { echo "not attended (${CLAUDE_CODE_SESSION_ATTENDED:-unset})"; return; }
  local environ="/proc/${CLAUDE_PID:-none}/environ"
  [ -r "$environ" ] || { echo "cannot read Claude process"; return; }
  if tr '\0' '\n' <"$environ" | grep -qx 'CLAUDE_CODE_CHILD_SESSION=1'; then echo "launched by another Claude session"; fi
}

# A pulled change to settings.json (declared plugins and marketplaces) installs what is missing.
install_if_changed() {
  if ! git diff --quiet "$before" HEAD -- settings.json && [ -f scripts/install.sh ]; then
    setsid nohup bash scripts/install.sh --plugins >>"$LOG" 2>&1 </dev/null &
  fi
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --status)
    echo "sync mode: $(current_mode)"
    exit 0
    ;;
  --mode)
    case "${2:-}" in
      auto | manual)
        echo "$2" >"$MODE_FILE"
        echo "sync mode: $2"
        exit 0
        ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  --now) event="Manual" ;;
  --overwrite) event="Manual"; action=overwrite ;;
  --reset) event="Manual"; action=reset ;;
  "")
    input="$(cat)"
    [ "$(current_mode)" = "auto" ] || exit 0
    [ -d "$REPO/.git" ] || exit 0
    parsed="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(d.get("hook_event_name", ""), d.get("agent_id") or "-")
' "$input" 2>/dev/null)"
    read -r event agent_id <<<"$parsed"
    event="${event:-}"
    agent_id="${agent_id:--}"
    reason="$(skip_reason)"
    if [ -n "$reason" ]; then
      log "skip: $reason"
      exit 0
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac

if [ ! -d "$REPO/.git" ]; then
  echo "config-sync: $REPO is not a git repo" >&2
  exit 1
fi

exec 9>"$REPO/.sync.lock"
if ! flock -n 9; then
  log "skip: lock held by another sync"
  if [ "$event" = "Manual" ]; then echo "config-sync: lock held by another sync, try again shortly"; fi
  stop
fi

cd "$REPO" || stop
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5'
export GIT_TERMINAL_PROMPT=0

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  warn "rebase in progress in $REPO, resolve it to resume syncing"
  stop
fi

# A repo can refresh generated files before the commit.
if [ -f scripts/pre-sync.sh ] && ! bash scripts/pre-sync.sh >>"$LOG" 2>&1; then
  warn "scripts/pre-sync.sh failed, sync stopped. See $LOG"
  stop
fi

# Model and effort in settings.json stay per device: /model and /effort rewrite them often, and syncing
# them caused conflicts. Before committing, put back the committed values and save this device's. On exit,
# success or failure, apply this device's values on top of whatever is now checked out.
DEVICE_KEYS_FILE="$(git rev-parse --git-path device-settings.json)"
device_keys() {
  python3 - "$1" "$DEVICE_KEYS_FILE" <<'PY'
import json, os, subprocess, sys
mode, saved = sys.argv[1:]
KEYS = ("model", "effortLevel", "modelSettings")
cur = json.load(open("settings.json"))
if mode == "save":
    json.dump({k: cur[k] for k in KEYS if k in cur}, open(saved, "w"))
    head = subprocess.run(["git", "show", "HEAD:settings.json"], capture_output=True, text=True)
    src = json.loads(head.stdout) if head.returncode == 0 else {}
elif os.path.exists(saved):
    src = json.load(open(saved))
    os.remove(saved)
else:
    sys.exit()
for k in KEYS:
    if k in src:
        cur[k] = src[k]
    else:
        cur.pop(k, None)
with open("settings.json", "w") as f:
    f.write(json.dumps(cur, indent=2, ensure_ascii=False) + "\n")
PY
}
if [ -f settings.json ]; then
  device_keys restore # a run that was killed may have left saved values
  device_keys save && trap 'device_keys restore' EXIT
fi
if [ "$action" = "reset" ]; then
  # No token scan: the backup commit stays on a local branch and is never pushed.
  if ! timeout 10 git fetch --quiet 2>/dev/null; then
    warn "fetch failed (network or SSH), nothing changed"
    stop
  fi
  before="$(git rev-parse HEAD)"
  backup=""
  git add -A
  if ! git diff --cached --quiet || [ "$(git rev-list --count '@{u}..HEAD')" != "0" ]; then
    if ! git diff --cached --quiet && ! git -c commit.gpgsign=false commit -qm "reset backup: $(hostname) $(date -Is)"; then
      git reset -q
      warn "backup commit failed, nothing changed"
      stop
    fi
    backup="reset-backup/$(date +%Y%m%d-%H%M%S)"
    git branch "$backup" HEAD
  fi
  if [ -z "$backup" ] && [ "$before" = "$(git rev-parse '@{u}')" ]; then
    echo "config-sync: already matches remote"
    exit 0
  fi
  git reset -q --hard '@{u}'
  log "ok: reset${backup:+, backup $backup}"
  install_if_changed
  echo "config-sync: reset to remote${backup:+, discarded local work saved on branch $backup}"
  exit 0
fi
[ -s "$PATTERNS" ] || { warn "$PATTERNS is missing, token scan cannot run, sync stopped"; stop; }
git add -A
matches="$(git grep --cached -I -l -E -f "$PATTERNS" 2>/dev/null)"
if [ -n "$matches" ]; then
  git reset -q
  warn "possible token found, sync stopped. Check: $(tr '\n' ' ' <<<"$matches")"
  stop
fi
committed=no
if ! git diff --cached --quiet; then
  if ! git -c commit.gpgsign=false commit -qm "sync: $(hostname) $(date -Is)"; then
    warn "commit failed, check git user.name and user.email"
    stop
  fi
  committed=yes
fi

# Closing a window with nothing to send stays offline, so exit is instant.
if [ "$event" = "SessionEnd" ] && [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)" = "0" ]; then
  exit 0
fi

before="$(git rev-parse HEAD)"
upstream_before="$(git rev-parse '@{u}' 2>/dev/null)"
replaced=0
if [ "$action" = "overwrite" ]; then
  # Merge with -s ours keeps this device's files and records the remote commits as merged, so the push
  # fast-forwards: no force push, and replaced commits stay in history for recovery.
  if ! timeout 10 git fetch --quiet 2>/dev/null; then
    warn "fetch failed (network or SSH), try again later"
    stop
  fi
  replaced="$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  if [ "$replaced" != "0" ] && ! git -c commit.gpgsign=false merge --quiet -s ours --no-edit \
    -m "overwrite: $(hostname) $(date -Is)" '@{u}' >/dev/null; then
    warn "overwrite merge failed, nothing pushed"
    stop
  fi
elif ! timeout 10 git pull --rebase --quiet 2>/dev/null; then
  if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    git rebase --abort
    warn "conflict with remote, local work kept and not pushed. Run git pull --rebase in $REPO to resolve"
  else
    warn "pull failed (network or SSH), try again later"
  fi
  stop
fi

pulled="$(git rev-list --count "$upstream_before..@{u}" 2>/dev/null || echo 0)"
pushed="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$pushed" != "0" ] && ! timeout 10 git push --quiet 2>/dev/null; then
  warn "push failed (network or SSH), try again later"
  stop
fi
log "ok: $event"

install_if_changed

if [ "$action" = "overwrite" ] && [ "$replaced" != "0" ]; then
  echo "config-sync: overwrote remote with this device, replaced $replaced remote commit(s), pushed $pushed commit(s)"
elif [ "$event" = "Manual" ]; then
  if [ "$committed" = "no" ] && [ "$pulled" = "0" ] && [ "$pushed" = "0" ]; then
    echo "config-sync: already up to date"
  else
    echo "config-sync: synced, pulled $pulled commit(s), pushed $pushed commit(s)"
  fi
fi

tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
exit 0
