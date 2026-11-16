#!/usr/bin/env bash
# Offline tests for config-sync.sh, verify-config-sync.sh, and install.sh.
# Uses a temporary bare remote and two fake home directories. Never touches the real ~/.claude or GitHub.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
pass=0; fail=0
CLAUDE_PROCS=()
cleanup() { kill "${CLAUDE_PROCS[@]}" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1

# Fake `gh` so verify's visibility check needs no network.
mkdir -p "$TMP/bin"
# FAKE_VISIBILITY="" stands for a repo whose visibility gh cannot read.
printf '#!/bin/sh\necho "$*" >> "%s/gh-args"\necho "${FAKE_VISIBILITY-PRIVATE}"\n' "$TMP" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Stand-ins for the Claude process that launched the hook. The guard reads this process's own environment.
env -u CLAUDE_CODE_CHILD_SESSION sleep 600 & TOP_PID=$!
CLAUDE_CODE_CHILD_SESSION=1 sleep 600 & NESTED_PID=$!
CLAUDE_PROCS+=("$TOP_PID" "$NESTED_PID")
sleep 0.2

git init -q --bare -b main "$TMP/remote.git"

seed() {
  local h="$TMP/seed/.claude"
  mkdir -p "$h/scripts" "$h/rules" "$h/dotconfig/tool"
  cp "$SRC/.gitignore" "$h/.gitignore"
  cp "$SRC/scripts/token-patterns.txt" "$SRC/scripts/tools.txt" "$h/scripts/"
  # Stub so the plugin step is observable and never runs the real CLI.
  printf '#!/bin/sh\ntouch "$HOME/plugin-step-ran"\n' > "$h/scripts/install.sh"
  echo 'first' > "$h/CLAUDE.md"
  echo 'tool config' > "$h/dotconfig/tool/config"
  printf '# comment lines are skipped\n\ntool\n' > "$h/dotconfig/links.txt"
  python3 - "$h/settings.json" <<'EOF'
import json, sys
hook = {"type": "command", "command": 'bash "$HOME/.claude/scripts/config-sync.sh"'}
json.dump({"hooks": {
    "SessionStart": [{"matcher": "^startup$", "hooks": [hook]}],
    "SessionEnd": [{"matcher": "^(prompt_input_exit|logout|other)$", "hooks": [hook]}],
}}, open(sys.argv[1], "w"), indent=2)
EOF
  git -C "$h" init -q -b main
  git -C "$h" add -A
  git -C "$h" commit -qm init
  git -C "$h" remote add origin "$TMP/remote.git"
  git -C "$h" push -qu origin main
}

clone_home() {
  mkdir -p "$TMP/$1"
  git clone -q "$TMP/remote.git" "$TMP/$1/.claude"
  mkdir -p "$TMP/$1/.config"
  ln -s "$TMP/$1/.claude/dotconfig/tool" "$TMP/$1/.config/tool"
}

# Usage: sync <home> <attended> <claude pid> <hook input JSON>
sync() {
  HOME="$TMP/$1" CLAUDE_CODE_SESSION_ATTENDED="$2" CLAUDE_PID="$3" \
    bash "$SRC/scripts/config-sync.sh" <<<"$4"
}
START='{"hook_event_name":"SessionStart","source":"startup"}'
END='{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}'
SUBAGENT='{"hook_event_name":"SessionStart","source":"startup","agent_id":"abc","agent_type":"Explore"}'

remote_head() { git -C "$TMP/remote.git" rev-parse main; }
log_of() { cat "$TMP/$1/.claude/.sync.log" 2>/dev/null; }

seed
clone_home a
clone_home b
# Hook tests below need auto mode. Manual mode has its own section.
echo auto > "$TMP/a/.claude/.sync-mode"
echo auto > "$TMP/b/.claude/.sync-mode"

# Positive control: without this, every "does nothing" case below could pass with a broken script.
echo changed-on-a > "$TMP/a/.claude/CLAUDE.md"
before="$(remote_head)"
sync a 1 "$TOP_PID" "$END"
check "user-opened window commits and pushes" '[ "$(remote_head)" != "$before" ]'
check "commit message names the host" 'git -C "$TMP/remote.git" log -1 --format=%s main | grep -q "^sync: $(hostname) "'
sync b 1 "$TOP_PID" "$START"
check "second device pulls the change" 'grep -q changed-on-a "$TMP/b/.claude/CLAUDE.md"'

# Guards: each session type that is not a user-opened window.
guarded() {
  local name="$1"; shift
  echo "edit-$name" >> "$TMP/a/.claude/CLAUDE.md"
  before="$(remote_head)"
  sync a "$@"
  check "$name does not push" '[ "$(remote_head)" = "$before" ]'
  check "$name leaves the edit uncommitted" '[ -n "$(git -C "$TMP/a/.claude" status --porcelain)" ]'
  check "$name logs why it skipped" 'log_of a | tail -1 | grep -q "skip"'
  git -C "$TMP/a/.claude" checkout -q -- CLAUDE.md
}
guarded "subagent input" 1 "$TOP_PID" "$SUBAGENT"
guarded "headless session" 0 "$TOP_PID" "$START"
guarded "session launched by Claude" 1 "$NESTED_PID" "$START"
guarded "missing attended signal" "" "$TOP_PID" "$START"
guarded "unreadable Claude process" 1 999999 "$START"
guarded "unparsable input" 1 "$TOP_PID" "not json"

# Allowlist.
echo fake > "$TMP/a/.claude/.credentials.json"
echo fake > "$TMP/a/.claude/mcp.json"
echo fake > "$TMP/a/.claude/history.jsonl"
mkdir -p "$TMP/a/.claude/projects/x/memory" "$TMP/a/.claude/skills/synced/x" "$TMP/a/.claude/skills/mine" "$TMP/a/.claude/agent-memory"
echo fake > "$TMP/a/.claude/projects/x/memory/MEMORY.md"
echo fake > "$TMP/a/.claude/skills/synced/x/SKILL.md"
echo fake > "$TMP/a/.claude/agent-memory/note.md"
echo mine > "$TMP/a/.claude/skills/mine/SKILL.md"
sync a 1 "$TOP_PID" "$END"
tracked="$(git -C "$TMP/a/.claude" ls-files)"
check "custom skill is tracked" 'grep -qx "skills/mine/SKILL.md" <<<"$tracked"'
check "credentials, memory, history, and synced skills are not tracked" \
  '! grep -qE "credentials|mcp\.json|history|projects/|agent-memory|skills/synced" <<<"$tracked"'

# Secret scan. The token is assembled at runtime so this file never matches the scan itself.
token="ghp_$(printf 'a%.0s' {1..36})"
mkdir -p "$TMP/a/.claude/rules"
echo "$token" >> "$TMP/a/.claude/rules/leak.md"
before="$(remote_head)"
out="$(sync a 1 "$TOP_PID" "$START")"
check "token blocks the push" '[ "$(remote_head)" = "$before" ]'
check "token warning reaches SessionStart output" 'grep -qi "token" <<<"$out"'
check "token warning does not print the token" '! grep -q "$token" <<<"$out$(log_of a)"'
check "token leaves nothing staged" 'git -C "$TMP/a/.claude" diff --cached --quiet'
rm "$TMP/a/.claude/rules/leak.md"

# Plugin step runs only when a pull changes settings.json.
sync b 1 "$TOP_PID" "$START"
rm -f "$TMP/b/plugin-step-ran"
python3 - "$TMP/a/.claude/settings.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["enabledPlugins"] = {"x@y": True}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
sync a 1 "$TOP_PID" "$END"
sync b 1 "$TOP_PID" "$START"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$TMP/b/plugin-step-ran" ] && break; sleep 0.2; done
check "pulled settings change runs the plugin step" '[ -e "$TMP/b/plugin-step-ran" ]'
rm -f "$TMP/b/plugin-step-ran"
sync b 1 "$TOP_PID" "$START"
sleep 0.4
check "pull with no settings change skips the plugin step" '[ ! -e "$TMP/b/plugin-step-ran" ]'

# Conflict: both devices edit the same line.
sync a 1 "$TOP_PID" "$START"
echo from-a > "$TMP/a/.claude/CLAUDE.md"
sync a 1 "$TOP_PID" "$END"
echo from-b > "$TMP/b/.claude/CLAUDE.md"
out="$(sync b 1 "$TOP_PID" "$START")"
check "conflict warns" 'grep -qi "conflict" <<<"$out"'
check "conflict leaves no rebase in progress" '[ ! -d "$TMP/b/.claude/.git/rebase-merge" ] && [ ! -d "$TMP/b/.claude/.git/rebase-apply" ]'
check "conflict keeps local work" 'grep -q from-b "$TMP/b/.claude/CLAUDE.md"'
check "conflict does not overwrite the remote" 'git -C "$TMP/remote.git" show main:CLAUDE.md | grep -q from-a'
git -C "$TMP/b/.claude" fetch -q origin
git -C "$TMP/b/.claude" reset -q --hard origin/main

# Model and effort stay per device: /model and /effort rewrite them often.
edit_settings() {
  python3 - "$TMP/$1/.claude/settings.json" "$2" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
exec(sys.argv[2])
json.dump(d, open(p, "w"), indent=2)
EOF
}
keys_of() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(json.dumps([d.get(k) for k in ("model", "effortLevel", "modelSettings")]))'; }
sync a 1 "$TOP_PID" "$START"; sync b 1 "$TOP_PID" "$START"
remote_keys="$(git -C "$TMP/remote.git" show main:settings.json | keys_of)"
edit_settings a 'd.update(model="opus", effortLevel="low", modelSettings={"m": {"effortLevel": "low"}}, timeFormat="24h")'
sync a 1 "$TOP_PID" "$END"
edit_settings b 'd.update(model="sonnet", effortLevel="high", modelSettings={"m": {"effortLevel": "high"}})'
out="$(sync b 1 "$TOP_PID" "$START")"
want_a='["opus", "low", {"m": {"effortLevel": "low"}}]'
want_b='["sonnet", "high", {"m": {"effortLevel": "high"}}]'
check "model and effort changes do not conflict" '! grep -qi "conflict" <<<"$out"'
check "model and effort are not pushed" '[ "$(git -C "$TMP/remote.git" show main:settings.json | keys_of)" = "$remote_keys" ]'
check "other settings still sync" 'grep -q "\"timeFormat\": \"24h\"" "$TMP/b/.claude/settings.json"'
check "each device keeps its own model and effort" '[ "$(keys_of <"$TMP/a/.claude/settings.json")" = "$want_a" ] && [ "$(keys_of <"$TMP/b/.claude/settings.json")" = "$want_b" ]'
check "device keys leave nothing to commit" '[ -z "$(git -C "$TMP/b/.claude" diff --cached)" ]'
for h in a b; do edit_settings "$h" 'for k in ("model", "effortLevel", "modelSettings"): d.pop(k, None)'; done

# Lock: a second run skips instead of waiting.
echo locked >> "$TMP/a/.claude/CLAUDE.md"
before="$(remote_head)"
( exec 9>"$TMP/a/.claude/.sync.lock"; flock 9; sleep 2 ) &
holder=$!
sleep 0.3
sync a 1 "$TOP_PID" "$END"
check "held lock skips the sync" '[ "$(remote_head)" = "$before" ] && log_of a | tail -1 | grep -q "skip.*lock"'
wait "$holder"
sync a 1 "$TOP_PID" "$END"
check "next run catches up after the lock" '[ "$(remote_head)" != "$before" ]'

# SessionEnd with nothing to do must stay offline.
git -C "$TMP/a/.claude" remote set-url origin "$TMP/does-not-exist.git"
out="$(sync a 1 "$TOP_PID" "$END")"
check "idle SessionEnd makes no network call" '! log_of a | tail -1 | grep -q WARN && [ -z "$out" ]'
out="$(sync a 1 "$TOP_PID" "$START")"
check "unreachable remote warns but exits cleanly" 'grep -qi "pull failed" <<<"$out"'
git -C "$TMP/a/.claude" remote set-url origin "$TMP/remote.git"

# Manual mode and the toggle. Runs with no Claude session signals, as from a terminal.
cmd() {
  local home="$1"; shift
  env -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID HOME="$TMP/$home" bash "$SRC/scripts/config-sync.sh" "$@" </dev/null
}
sync a 1 "$TOP_PID" "$START" >/dev/null
sync b 1 "$TOP_PID" "$START" >/dev/null

rm "$TMP/a/.claude/.sync-mode"
check "mode defaults to manual" 'cmd a --status | grep -q "manual"'
echo default-mode >> "$TMP/a/.claude/CLAUDE.md"
before="$(remote_head)"
sync a 1 "$TOP_PID" "$END"
check "hook does nothing with no mode file" '[ "$(remote_head)" = "$before" ] && [ -n "$(git -C "$TMP/a/.claude" status --porcelain)" ]'

cmd a --mode manual >/dev/null
sync a 1 "$TOP_PID" "$START"
check "hook does nothing in manual mode" '[ "$(remote_head)" = "$before" ] && [ -n "$(git -C "$TMP/a/.claude" status --porcelain)" ]'

out="$(cmd a --now)"; rc=$?
check "manual sync pushes in manual mode" '[ "$rc" -eq 0 ] && [ "$(remote_head)" != "$before" ]'
check "manual sync reports what it pushed" 'grep -q "pushed 1" <<<"$out"'
cmd b --mode manual >/dev/null
out="$(cmd b --now)"; rc=$?
check "manual sync pulls on the other device" '[ "$rc" -eq 0 ] && grep -q default-mode "$TMP/b/.claude/CLAUDE.md" && grep -q "pulled 1" <<<"$out"'
out="$(cmd b --now)"; rc=$?
check "manual sync with nothing to do succeeds and says so" '[ "$rc" -eq 0 ] && grep -qi "up to date" <<<"$out"'
check "mode file is never tracked" '! git -C "$TMP/a/.claude" ls-files | grep -q sync-mode'

out="$(cmd a --mode sometimes 2>&1)"; rc=$?
check "invalid mode is rejected" '[ "$rc" -ne 0 ] && [ "$(cat "$TMP/a/.claude/.sync-mode")" = "manual" ]'
cmd a --unknown >/dev/null 2>&1; rc=$?
check "unknown argument is rejected" '[ "$rc" -ne 0 ]'
before="$(remote_head)"
out="$(cmd a --help)"; rc=$?
check "help lists every option and syncs nothing" \
  '[ "$rc" -eq 0 ] && grep -q -- --reset <<<"$out" && grep -q -- --help <<<"$out" && [ "$(remote_head)" = "$before" ]'

cmd a --mode auto >/dev/null
check "status reports auto after toggling" 'cmd a --status | grep -q "auto"'
echo back-to-auto >> "$TMP/a/.claude/CLAUDE.md"
before="$(remote_head)"
sync a 1 "$TOP_PID" "$END"
check "hook syncs again after toggling to auto" '[ "$(remote_head)" != "$before" ]'

# Manual failures must be visible, because no later window start reports them.
cmd a --mode manual >/dev/null
mkdir -p "$TMP/a/.claude/rules"
echo "$token" > "$TMP/a/.claude/rules/leak.md"
out="$(cmd a --now)"; rc=$?
check "manual sync fails loudly on a token" '[ "$rc" -ne 0 ] && grep -qi "token" <<<"$out" && ! grep -q "$token" <<<"$out"'
rm "$TMP/a/.claude/rules/leak.md"

cmd a --now >/dev/null
cmd b --now >/dev/null
echo conflict-a > "$TMP/a/.claude/CLAUDE.md"
cmd a --now >/dev/null
echo conflict-b > "$TMP/b/.claude/CLAUDE.md"
out="$(cmd b --now)"; rc=$?
check "manual sync fails loudly on a conflict" '[ "$rc" -ne 0 ] && grep -qi "conflict" <<<"$out" && grep -q conflict-b "$TMP/b/.claude/CLAUDE.md"'
git -C "$TMP/b/.claude" fetch -q origin
git -C "$TMP/b/.claude" reset -q --hard origin/main

( exec 9>"$TMP/a/.claude/.sync.lock"; flock 9; sleep 1.5 ) &
holder=$!
sleep 0.3
out="$(cmd a --now)"; rc=$?
check "manual sync reports a held lock" '[ "$rc" -ne 0 ] && grep -qi "lock" <<<"$out"'
wait "$holder"

cmd a --mode manual >/dev/null
out="$(HOME="$TMP/a" bash "$SRC/scripts/verify-config-sync.sh" 2>&1)"
check "verify reports the sync mode" 'grep -q "^INFO sync mode: manual" <<<"$out"'
cmd a --mode auto >/dev/null

# --overwrite makes the remote match this device with a normal push, keeping replaced commits in history.
cmd a --now >/dev/null; cmd b --now >/dev/null
mkdir -p "$TMP/b/.claude/rules"
echo from-b > "$TMP/b/.claude/rules/b-only.md"
sed -i '1s/.*/b-line/' "$TMP/b/.claude/CLAUDE.md"
cmd b --now >/dev/null
b_commit="$(remote_head)"
sed -i '1s/.*/a-line/' "$TMP/a/.claude/CLAUDE.md"
out="$(cmd a --overwrite)"; rc=$?
check "overwrite succeeds where a sync would conflict" '[ "$rc" -eq 0 ] && grep -q "overwrote remote" <<<"$out"'
check "overwrite leaves the remote equal to this device" '[ "$(git -C "$TMP/remote.git" rev-parse "main^{tree}")" = "$(git -C "$TMP/a/.claude" rev-parse "HEAD^{tree}")" ] && [ "$(git -C "$TMP/remote.git" show main:CLAUDE.md | head -1)" = a-line ] && ! git -C "$TMP/remote.git" cat-file -e main:rules/b-only.md 2>/dev/null'
check "overwrite keeps replaced commits in history" 'git -C "$TMP/remote.git" merge-base --is-ancestor "$b_commit" main'
out="$(cmd b --now)"; rc=$?
check "other device pulls the overwrite cleanly" '[ "$rc" -eq 0 ] && [ "$(head -1 "$TMP/b/.claude/CLAUDE.md")" = a-line ] && [ ! -e "$TMP/b/.claude/rules/b-only.md" ]'
out="$(cmd a --overwrite)"; rc=$?
check "overwrite with nothing to replace is up to date" '[ "$rc" -eq 0 ] && grep -q "already up to date" <<<"$out"'

# --reset makes this device match the remote and keeps the discarded work on a local backup branch.
cmd a --now >/dev/null; cmd b --now >/dev/null
echo pending > "$TMP/a/.claude/rules/a-pending.md"
sed -i '1s/.*/a-local/' "$TMP/a/.claude/CLAUDE.md"
echo local-only > "$TMP/a/.claude/.credentials.json"
sed -i '1s/.*/b-remote/' "$TMP/b/.claude/CLAUDE.md"
cmd b --now >/dev/null
remote_before="$(remote_head)"
out="$(cmd a --reset)"; rc=$?
check "reset succeeds and says so" '[ "$rc" -eq 0 ] && grep -q "reset to remote" <<<"$out"'
check "reset leaves this device equal to the remote" '[ "$(git -C "$TMP/a/.claude" rev-parse HEAD)" = "$(remote_head)" ] && [ "$(head -1 "$TMP/a/.claude/CLAUDE.md")" = b-remote ] && [ ! -e "$TMP/a/.claude/rules/a-pending.md" ] && [ -z "$(git -C "$TMP/a/.claude" status --porcelain)" ]'
check "reset keeps local-only files" '[ "$(cat "$TMP/a/.claude/.credentials.json")" = local-only ]'
backup="$(git -C "$TMP/a/.claude" for-each-ref --format="%(refname:short)" refs/heads/reset-backup/ | tail -1)"
check "reset saves discarded work on a backup branch" '[ -n "$backup" ] && git -C "$TMP/a/.claude" cat-file -e "$backup:rules/a-pending.md" && [ "$(git -C "$TMP/a/.claude" show "$backup:CLAUDE.md" | head -1)" = a-local ] && ! git -C "$TMP/a/.claude" cat-file -e "$backup:.credentials.json" 2>/dev/null'
check "reset pushes nothing" '[ "$(remote_head)" = "$remote_before" ] && ! git -C "$TMP/remote.git" show-ref --quiet --heads reset-backup'
cmd a --now >/dev/null
check "next sync does not bring discarded edits back" '[ "$(git -C "$TMP/remote.git" show main:CLAUDE.md | head -1)" = b-remote ] && ! git -C "$TMP/remote.git" cat-file -e main:rules/a-pending.md 2>/dev/null'
out="$(cmd a --reset)"; rc=$?
check "reset when already matching changes nothing" '[ "$rc" -eq 0 ] && grep -q "already matches remote" <<<"$out" && [ "$(git -C "$TMP/a/.claude" for-each-ref refs/heads/reset-backup/ | wc -l)" -eq 1 ]'
git -C "$TMP/a/.claude" remote set-url origin "$TMP/nowhere.git"
echo offline-edit >> "$TMP/a/.claude/CLAUDE.md"
out="$(cmd a --reset)"; rc=$?
check "reset with no network changes nothing" '[ "$rc" -ne 0 ] && grep -qi "fetch failed" <<<"$out" && grep -q offline-edit "$TMP/a/.claude/CLAUDE.md"'
git -C "$TMP/a/.claude" checkout -q -- CLAUDE.md
git -C "$TMP/a/.claude" remote set-url origin "$TMP/remote.git"

# A repo can ship scripts/pre-sync.sh to refresh generated files before the commit.
cmd a --now >/dev/null
printf 'mkdir -p rules && echo generated > rules/generated.md\n' > "$TMP/a/.claude/scripts/pre-sync.sh"
out="$(cmd a --now)"; rc=$?
check "pre-sync.sh runs before the commit" '[ "$rc" -eq 0 ] && [ "$(git -C "$TMP/a/.claude" show HEAD:rules/generated.md)" = generated ]'
printf 'exit 1\n' > "$TMP/a/.claude/scripts/pre-sync.sh"
before_a="$(git -C "$TMP/a/.claude" rev-parse HEAD)"
out="$(cmd a --now)"; rc=$?
check "failing pre-sync.sh stops the sync" '[ "$rc" -ne 0 ] && grep -q "pre-sync.sh failed" <<<"$out" && [ "$(git -C "$TMP/a/.claude" rev-parse HEAD)" = "$before_a" ]'
rm "$TMP/a/.claude/scripts/pre-sync.sh"
cmd a --now >/dev/null

# verify-config-sync.sh.
verify() {
  env -u WSL_DISTRO_NAME HOME="$TMP/a" bash "$SRC/scripts/verify-config-sync.sh" 2>&1
}
sync a 1 "$TOP_PID" "$START"
head_before="$(git -C "$TMP/a/.claude" rev-parse HEAD)"
status_before="$(git -C "$TMP/a/.claude" status --porcelain)"
out="$(verify)"; rc=$?
check "verify passes on a clean setup" '[ "$rc" -eq 0 ] && ! grep -q "^FAIL" <<<"$out" && grep -q "^PASS" <<<"$out"'
check "verify changes nothing" '[ "$(git -C "$TMP/a/.claude" rev-parse HEAD)" = "$head_before" ] && [ "$(git -C "$TMP/a/.claude" status --porcelain)" = "$status_before" ]'

# Per-device keys always differ from the committed settings.json, and no sync commits them.
edit_settings a 'd.update(model="opus", effortLevel="low")'
out="$(verify)"
check "verify does not count per-device keys as uncommitted changes" 'grep -q "^PASS no uncommitted changes" <<<"$out"'
edit_settings a 'd["theme"] = "light"'
out="$(verify)"
check "verify counts other settings changes as uncommitted" 'grep -q "^WARN 1 uncommitted change" <<<"$out"'
edit_settings a 'for k in ("model", "effortLevel", "theme"): d.pop(k, None)'
git -C "$TMP/a/.claude" checkout -q -- settings.json

expect_fail() {
  out="$(verify)"; rc=$?
  check "verify fails on $1" '[ "$rc" -ne 0 ] && grep -q "^FAIL" <<<"$out"'
}
FAKE_VISIBILITY=PUBLIC expect_fail "a public repo"

git -C "$TMP/a/.claude" add -f .credentials.json
git -C "$TMP/a/.claude" commit -qm bad
expect_fail "a tracked credentials file"
git -C "$TMP/a/.claude" reset -q --hard "$head_before"

mv "$TMP/a/.claude/settings.json" "$TMP/settings.keep"
python3 -c "import json,sys; json.dump({'hooks':{}}, open(sys.argv[1],'w'))" "$TMP/a/.claude/settings.json"
expect_fail "a removed sync hook"
echo '{broken' > "$TMP/a/.claude/settings.json"
expect_fail "invalid settings JSON"
mv "$TMP/settings.keep" "$TMP/a/.claude/settings.json"

rm "$TMP/a/.config/tool"
ln -s "$TMP/nowhere" "$TMP/a/.config/tool"
expect_fail "a broken symlink"
rm "$TMP/a/.config/tool"
echo replaced > "$TMP/a/.config/tool"
expect_fail "a link replaced by a regular file"
rm "$TMP/a/.config/tool"
ln -s "$TMP/a/.claude/dotconfig/tool" "$TMP/a/.config/tool"

mkdir -p "$TMP/a/.claude/rules"
echo "$token" > "$TMP/a/.claude/rules/leak.md"
git -C "$TMP/a/.claude" add rules/leak.md
git -C "$TMP/a/.claude" commit -qm bad
expect_fail "a tracked token"
git -C "$TMP/a/.claude" reset -q --hard "$head_before"

out="$(verify)"
check "verify reports the origin URL" 'grep -q "^PASS origin is $TMP/remote.git" <<<"$out"'
# gh picks an "upstream" remote over origin when run without a repo, and the README adds upstream for updates.
check "verify asks gh about origin by URL" 'tail -1 "$TMP/gh-args" | grep -q "^repo view $TMP/remote.git "'
check "verify skips comment lines in links.txt" '! grep -q "config/#" <<<"$out"'
url="$(git -C "$TMP/a/.claude" remote get-url origin)"
git -C "$TMP/a/.claude" remote remove origin
expect_fail "a missing origin"
git -C "$TMP/a/.claude" remote add origin "$url"
git -C "$TMP/a/.claude" fetch -q origin
git -C "$TMP/a/.claude" branch -q -u origin/main
out="$(FAKE_VISIBILITY="" verify)"; rc=$?
check "verify warns when visibility is unknown (not GitHub, or no gh login)" '[ "$rc" -eq 0 ] && grep -q "^WARN could not read repo visibility" <<<"$out"'

# Tools come from scripts/tools.txt, which each user extends with their own CLIs.
echo "no-such-tool-xyz  https://example.invalid/install" >> "$TMP/a/.claude/scripts/tools.txt"
out="$(verify)"; rc=$?
check "verify warns about a missing tool from tools.txt with its hint" '[ "$rc" -eq 0 ] && grep -q "^WARN no-such-tool-xyz is not on PATH: https://example.invalid/install" <<<"$out"'
check "verify skips comment lines in tools.txt" '! grep -q "^WARN # " <<<"$out"'
git -C "$TMP/a/.claude" checkout -q -- scripts/tools.txt

# Absolute paths into another user's home break on devices with a different home.
edit_settings a 'd["statusLine"] = {"type": "command", "command": "/home/nobody-xyz/bin/status"}'
out="$(verify)"; rc=$?
check "verify warns about absolute paths outside this home" '[ "$rc" -eq 0 ] && grep -q "^WARN settings.json has absolute paths outside $TMP/a: /home/nobody-xyz" <<<"$out"'
edit_settings a 'd["statusLine"] = {"type": "command", "command": "'"$TMP/a"'/bin/status"}'
out="$(verify)"
check "verify accepts absolute paths inside this home" '! grep -q "absolute paths outside" <<<"$out"'
edit_settings a 'd.pop("statusLine", None)'

# Windows tools writing over \\wsl$ drop exec bits, so on WSL tracked file modes must be ignored.
git -C "$TMP/a/.claude" config core.fileMode true
out="$(WSL_DISTRO_NAME=Ubuntu HOME="$TMP/a" bash "$SRC/scripts/verify-config-sync.sh" 2>&1)"; rc=$?
check "verify warns on WSL when core.fileMode is true" '[ "$rc" -eq 0 ] && grep -q "^WARN core.fileMode" <<<"$out"'
out="$(verify)"
check "verify ignores core.fileMode outside WSL" '! grep -q "core.fileMode" <<<"$out"'
git -C "$TMP/a/.claude" config core.fileMode false
out="$(WSL_DISTRO_NAME=Ubuntu HOME="$TMP/a" bash "$SRC/scripts/verify-config-sync.sh" 2>&1)"
check "verify accepts core.fileMode false on WSL" 'grep -q "^PASS core.fileMode is false" <<<"$out"'

out="$(verify)"; rc=$?
check "verify passes again after repairs" '[ "$rc" -eq 0 ]'

# install.sh adds the sync hooks to an existing settings.json without touching anything else.
install() { env -u WSL_DISTRO_NAME HOME="$TMP/$1" bash "$SRC/scripts/install.sh" 2>&1; }
hooks_of() {
  python3 - "$TMP/$1/.claude/settings.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for event in ("SessionStart", "SessionEnd"):
    groups = [g for g in d.get("hooks", {}).get(event, []) if any("config-sync.sh" in h.get("command", "") for h in g.get("hooks", []))]
    print(event, len(groups), groups[0]["matcher"] if groups else "-")
EOF
}
clone_home c
rm "$TMP/c/.config/tool"
python3 - "$TMP/c/.claude/settings.json" <<'EOF'
import json, sys
json.dump({"theme": "dark", "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "echo mine"}]}]}},
          open(sys.argv[1], "w"), indent=2)
EOF
out="$(install c)"; rc=$?
want_hooks="$(printf 'SessionStart 1 ^startup$\nSessionEnd 1 ^(prompt_input_exit|logout|other)$')"
check "install adds both sync hooks" '[ "$rc" -eq 0 ] && [ "$(hooks_of c)" = "$want_hooks" ]'
check "install keeps the user's own hooks and settings" 'grep -q "echo mine" "$TMP/c/.claude/settings.json" && grep -q "\"theme\": \"dark\"" "$TMP/c/.claude/settings.json"'
sum_before="$(cksum <"$TMP/c/.claude/settings.json")"
install c >/dev/null
check "install is idempotent" '[ "$(hooks_of c)" = "$want_hooks" ] && [ "$(cksum <"$TMP/c/.claude/settings.json")" = "$sum_before" ]'
check "install links configs from links.txt" '[ -L "$TMP/c/.config/tool" ] && [ "$(readlink -f "$TMP/c/.config/tool")" = "$(readlink -f "$TMP/c/.claude/dotconfig/tool")" ]'
check "install skips comment lines in links.txt" '[ ! -e "$TMP/c/.config/# comment lines are skipped" ] && ! grep -q "comment lines" <<<"$out"'
echo "no-such-tool-xyz  https://example.invalid/install" >> "$TMP/c/.claude/scripts/tools.txt"
out="$(install c)"
check "install reports missing tools from tools.txt" 'grep -q "^MISSING no-such-tool-xyz: https://example.invalid/install" <<<"$out"'
check "install leaves file modes alone outside WSL" '[ "$(git -C "$TMP/c/.claude" config --bool core.fileMode)" != false ]'
WSL_DISTRO_NAME=Ubuntu HOME="$TMP/c" bash "$SRC/scripts/install.sh" >/dev/null 2>&1
check "install sets core.fileMode false on WSL" '[ "$(git -C "$TMP/c/.claude" config --bool core.fileMode)" = false ]'

rm "$TMP/c/.claude/settings.json"
install c >/dev/null
check "install creates settings.json when there is none" '[ "$(hooks_of c)" = "$want_hooks" ]'
echo '{broken' > "$TMP/c/.claude/settings.json"
out="$(install c)"
check "install leaves an invalid settings.json alone and warns" '[ "$(cat "$TMP/c/.claude/settings.json")" = "{broken" ] && grep -q "^WARN settings.json" <<<"$out"'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
