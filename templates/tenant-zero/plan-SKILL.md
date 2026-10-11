---
name: plan
description: The owner's planning loop. Reachable by its name only.
disable-model-invocation: true
allowed-tools: Bash(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill plan repo)
---

This stub carries no instructions of its own. The skill's instructions live in
the apparatus checkout, so they can change without this repository changing.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill plan repo

If it prints nothing, the planning loop is not open on this channel, or the skill is not
in the checkout yet. Say so in one line and go on without it.
