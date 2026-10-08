---
name: read-draft
description: Read a draft before the person it is for sees it. Use before a substantive reply, a message a customer will read, or a document handed to someone. The reader restates every sentence and quotes what it could not restate, what advances nothing that was asked, and which claims have no source. It flags; it never rewrites.
allowed-tools: Bash(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill read-draft repo)
---

This stub carries no instructions of its own. The reader's instructions live in the
apparatus checkout, so they can change without this repository changing. This copy is
committed so a cloud session, which loads no plugin, has the reader too.

Run this command with the Bash tool, from the project directory, and follow what it prints:

    bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill read-draft repo

If it prints nothing, this repository is not one the apparatus acts in, or the reader
is not in the checkout yet. Say so in one line and go on without the reader.
