---
name: verify-config-sync
description: Verify the ~/.claude config sync is healthy on this device. Checks repo privacy, sync state, tracked files, hooks, symlinks, plugins, and tools.
argument-hint: "[test]"
disable-model-invocation: true
---

# Verify config sync

Check the health of the `~/.claude` git sync on this device.

## Steps

1. Run the check. If the arguments include `test`, add `--test` to also run the offline test suite.

   ```bash
   bash "$HOME/.claude/scripts/verify-config-sync.sh"
   ```

2. Report the result: `FAIL` items first, then `WARN` items, then a one-line count of `PASS` items. Include the `INFO` lines on last sync per device and skip reasons.

3. For each `FAIL` or `WARN`, explain the cause and propose a fix. See "Sync" and "Troubleshooting" in `~/.claude/README.md`.

## Rules

- Do not change anything during the check. Apply a fix only after the user approves it.
- If the check reports a possible token, name the file only. Do not print the matching line.
- A token that reached the remote is compromised. Say so, and tell the user to revoke it. Removing it from git is not enough.
