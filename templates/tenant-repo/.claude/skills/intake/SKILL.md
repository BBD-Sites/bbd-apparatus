---
name: intake
description: Set up or add to the owner's rules, areas and projects. Use on a first session, or when the owner says they want to add a business, a project or a part of their life. It asks in plain words, writes the files and reads them back.
allowed-tools: Bash(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill intake repo)
---

This stub carries no instructions of its own. The skill's instructions live in
the apparatus checkout, so they can change without this repository changing. This copy is committed so a cloud session, which loads no plugin, has the skill too.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill intake repo

If it prints nothing, this repository is not one the apparatus acts in, or the skill
is not in the checkout yet. Say so in one line and go on without it.
