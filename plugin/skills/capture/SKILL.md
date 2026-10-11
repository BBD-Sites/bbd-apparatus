---
name: capture
description: Decide what to do with something the owner dumps. It keeps it whole, files it under a project, or makes it a change. Also routes a file that is too big for the repository. Use for any dump, link, file, recording or list of many things.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill capture)
---

This stub carries no instructions of its own. The skill's instructions live in
the apparatus checkout, so they can change without this plugin changing.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill capture

If it prints nothing, this repository is not one the apparatus acts in, or the skill
is not in the checkout yet. Say so in one line and go on without it.
