# bbd-apparatus

The apparatus a memory-platform tenant's Claude Code runs through hooks: a launcher that
fast-forwards this checkout and runs the current scripts; the redactor and its self-test;
the shipper that moves a redacted transcript to the tenant's own store; the thin plugin
shell and the marketplace that deliver the launcher; and the one-command installer.

Two channels: `stable` (every tenant) and `next` (the maintainers' own tenant first).
Promotion is a merge from `next` to `stable`.

This repository is public and read-only to every machine that runs it. By rule it carries
no secret, no token and no name of any person or business, and a test refuses a commit that
does. Behaviour lives here; the plugin's hook entries never change.

All rights reserved. Source is published so that every tenant can read exactly what runs on
their machine.

## Tests

Plain bash, so they run on a stock Mac (bash 3.2, no jq) and on Linux:

```
bash tests/run.sh
shellcheck tests/*.sh tests/lib/*.sh
```

The name audit reads its deny-list from outside the repository: `$NAME_DENYLIST_FILE`,
else `~/.config/bbd-apparatus/denylist.txt`, else the `NAME_DENYLIST` Actions secret in
CI, where an empty list fails the run. Merges are rebase only, so every commit keeps the
neutral author and its committer is either that identity or GitHub's own web-flow
identity; the audit accepts nothing else. The launcher's contract is
`docs/launcher-contract.md`.
What the redactor removes, and its two checks, are in `docs/redaction.md`.
