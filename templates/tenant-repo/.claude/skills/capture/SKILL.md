---
name: capture
description: Decide what to do with something the owner dumps. It keeps it whole, files it under a project, or makes it a change. Also routes a file that is too big for the repository. Use for any dump, link, file, recording or list of many things.
allowed-tools: Bash(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill capture repo)
---

This stub carries no instructions of its own. The skill's instructions live in
the apparatus checkout, so they can change without this repository changing. This copy is committed so a cloud session, which loads no plugin, has the skill too.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill capture repo

If it prints nothing, this repository is not one the apparatus acts in, or the skill
is not in the checkout yet. Say so in one line and go on without it.
