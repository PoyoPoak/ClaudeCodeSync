---
name: sync-config
description: Sync ~/.claude with its private git repo now, overwrite the repo with this device's config, reset this device to the repo, switch this device between manual and automatic sync, or list these options.
argument-hint: "[overwrite | reset | auto | manual | status | help]"
disable-model-invocation: true
---

# Sync config

Run one command based on the arguments, then report its output in one or two lines.

| Arguments | Command |
| --- | --- |
| none | `bash "$HOME/.claude/scripts/config-sync.sh" --now` |
| `overwrite` | `bash "$HOME/.claude/scripts/config-sync.sh" --overwrite` |
| `reset` | `bash "$HOME/.claude/scripts/config-sync.sh" --reset` |
| `auto` | `bash "$HOME/.claude/scripts/config-sync.sh" --mode auto` |
| `manual` | `bash "$HOME/.claude/scripts/config-sync.sh" --mode manual` |
| `status` | `bash "$HOME/.claude/scripts/config-sync.sh" --status` |
| `help` | `grep '^| ./sync-config' "$HOME/.claude/README.md"` |

## Rules

- For `help`, show the output as a table and run nothing else.
- The mode applies to this device only. In `auto`, windows sync when they open and close. In `manual`, only `/sync-config` syncs.
- Switching mode does not sync anything.
- `overwrite` makes the remote match this device's tracked files and drops other devices' unsynced changes from the current state. Report how many remote commits it replaced. They stay in git history, so recovery is possible (see "Troubleshooting" in `~/.claude/README.md`).
- `reset` makes this device match the remote and pushes nothing. Pending edits are saved on a local `reset-backup/<time>` branch. Report the branch name. Local-only files (credentials, memory) are never touched.
- If the sync fails, explain the message and propose a fix from "Troubleshooting" in `~/.claude/README.md`. Apply a fix only after the user approves it.
- If the sync reports a possible token, name the file only. Do not print the matching line.
