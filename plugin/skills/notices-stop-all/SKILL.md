---
name: notices-stop-all
description: Stop every keep-current notice, for good, on this account home. Use when the person says they do not want to hear every keep-current notice: the newer Claude Code, the newer model and the fresh-session advice again. It records the stop; it never switches anything else, and the person can always ask again.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill notices-stop-all)
---

This stub carries no instructions of its own. What it turns off is every keep-current notice: the newer Claude Code, the newer model and the fresh-session advice; the record it writes lives in the apparatus checkout's state, so the rule can change without this plugin changing.

Run this command with the Bash tool, from the project directory, and say what it prints in one sentence:

    bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill notices-stop-all

If it prints nothing, this repository is not one the apparatus acts in, or the stop is
not in the checkout yet. Say so in one line.
