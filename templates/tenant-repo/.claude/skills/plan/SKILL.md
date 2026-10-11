---
name: plan
description: Keep the owner's to-dos, today's list, the weekly review, what they are waiting on, and plans from tomorrow to five years. Use when they say what they need to do, ask what today looks like, ask for a weekly review, or say their plans changed.
allowed-tools: Bash(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill plan repo)
---

This stub carries no instructions of its own. The skill's instructions live in
the apparatus checkout, so they can change without this repository changing. This copy is committed so a cloud session, which loads no plugin, has the skill too.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill plan repo

If it prints nothing, this repository is not one the apparatus acts in, or the skill
is not in the checkout yet. Say so in one line and go on without it.
