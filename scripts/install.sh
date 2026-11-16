#!/usr/bin/env bash
# Set up this device after the config repo is in ~/.claude. Safe to run repeatedly.
# Usage: install.sh              file modes (WSL), links, sync hooks, plugins, and tool report
#        install.sh --plugins    install enabled plugins that are missing
#        install.sh --dry-run    show what the plugin step would do
set -uo pipefail

REPO="$HOME/.claude"
mode="${1:-all}"

# Windows tools (Fork, editors) writing over \\wsl$ drop exec bits. Restore any drifted modes, then stop
# git tracking modes so it cannot recur. .git/config does not sync, so this runs once per device.
fix_file_modes() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || return 0
  git -C "$REPO" diff --summary | awk '/mode change/{print $NF}' | xargs -r git -C "$REPO" checkout --
  git -C "$REPO" config core.fileMode false
}

link_configs() {
  local stamp rel link target
  stamp="$(date +%Y%m%d%H%M%S)"
  [ -f "$REPO/dotconfig/links.txt" ] || return 0
  while read -r rel; do
    case "$rel" in "" | "#"*) continue ;; esac
    link="$HOME/.config/$rel"
    target="$REPO/dotconfig/$rel"
    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target")" ]; then
      continue
    fi
    if [ ! -e "$target" ]; then
      # First device: the local copy becomes the synced copy.
      [ -e "$link" ] || { echo "skip $rel: no local copy and none in the repo"; continue; }
      mkdir -p "$(dirname "$target")"
      mv "$link" "$target"
    elif [ -e "$link" ] || [ -L "$link" ]; then
      mv "$link" "$link.bak.$stamp"
      echo "backed up ~/.config/$rel to $link.bak.$stamp"
    fi
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
    echo "linked ~/.config/$rel"
  done <"$REPO/dotconfig/links.txt"
}

# Adds the SessionStart and SessionEnd sync hooks to settings.json if they are missing. Leaves every other
# setting and hook as it is, and writes nothing when both hooks are already there.
add_sync_hooks() {
  python3 - "$REPO/settings.json" <<'EOF'
import json, os, sys
path = sys.argv[1]
try:
    settings = json.load(open(path)) if os.path.exists(path) else {}
except ValueError:
    print("WARN settings.json is not valid JSON, sync hooks not added. Fix it and rerun install.sh")
    raise SystemExit
command = 'bash "$HOME/.claude/scripts/config-sync.sh"'
wanted = {"SessionStart": ("^startup$", 30), "SessionEnd": ("^(prompt_input_exit|logout|other)$", 25)}
hooks = settings.setdefault("hooks", {})
added = []
for event, (matcher, timeout) in wanted.items():
    groups = hooks.setdefault(event, [])
    if not any("config-sync.sh" in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]})
        added.append(event)
if added:
    with open(path, "w") as f:
        f.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print("added sync hooks to settings.json: " + ", ".join(added))
EOF
}

# Prints "marketplace <source>" and "plugin <id>" lines for everything enabled but not installed.
plugin_plan() {
  python3 - "$REPO" <<'EOF'
import json, os, sys
repo = sys.argv[1]
def load(path):
    try:
        return json.load(open(os.path.join(repo, path)))
    except (OSError, ValueError):
        return {}
settings = load("settings.json")
data = load("plugins/installed_plugins.json")
installed = set(data.get("plugins", data))
known = set(load("plugins/known_marketplaces.json"))
for name, entry in settings.get("extraKnownMarketplaces", {}).items():
    src = entry.get("source", {})
    location = src.get("repo") or src.get("url")
    if name not in known and location:
        print("marketplace", location)
for plugin, enabled in settings.get("enabledPlugins", {}).items():
    # @builtin plugins ship with Claude Code.
    if enabled and plugin not in installed and not plugin.endswith("@builtin"):
        print("plugin", plugin)
EOF
}

install_plugins() {
  local kind value
  while read -r kind value; do
    case "$kind" in
      marketplace) claude plugin marketplace add "$value" || echo "WARN could not add marketplace $value" ;;
      plugin) claude plugin install "$value" || echo "WARN could not install plugin $value" ;;
    esac
  done < <(plugin_plan)
}

# scripts/tools.txt lists the CLIs this config needs, one "<command> <install hint>" per line.
check_tools() {
  local tool hint
  [ -f "$REPO/scripts/tools.txt" ] || return 0
  while read -r tool hint; do
    case "$tool" in "" | "#"*) continue ;; esac
    command -v "$tool" >/dev/null || echo "MISSING $tool: $hint"
  done <"$REPO/scripts/tools.txt"
}

case "$mode" in
  --plugins) install_plugins ;;
  --dry-run) plugin_plan ;;
  all)
    fix_file_modes
    link_configs
    add_sync_hooks
    install_plugins
    check_tools
    ;;
  *) echo "usage: install.sh [--plugins|--dry-run]" >&2; exit 2 ;;
esac
