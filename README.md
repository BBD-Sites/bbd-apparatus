# bbd-apparatus

The apparatus a memory-platform tenant's Claude Code runs through hooks: a launcher that
fast-forwards this checkout and runs the current scripts; the redactor and its self-test;
the shipper that moves a redacted transcript to the tenant's own store; the thin plugin
shell and the marketplace that deliver the launcher; and the one-command installer.

Two channels: `stable` (every tenant) and `next` (the maintainers' own tenant first).
Promotion is a fast-forward of `next`'s head to `stable` (`docs/channels.md`).

This repository is public and read-only to every machine that runs it. By rule it carries
no secret, no token and no name of any person or business, and a test refuses a commit that
does. Behaviour lives here; the plugin's hook entries never change.

All rights reserved. Source is published so that every tenant can read exactly what runs on
their machine.

## Install

The marketplace is this repository (`.claude-plugin/marketplace.json`, name
`bbd-apparatus`); the plugin is `plugin/` (name `bbd`, so its id is `bbd@bbd-apparatus`
and its skills are `/bbd:read-draft` and the four `/bbd:notices-stop-<kind>` stops). By hand, in any Claude Code session or shell:

```
claude plugin marketplace add BBD-Sites/bbd-apparatus
claude plugin install bbd@bbd-apparatus --scope user
```

The plugin carries the maintainers' public key (`plugin/allowed_signers`), and the
launcher runs no channel head that key did not sign (`docs/channels.md`). Nothing installs
while no signers file exists: the one-command installer, the next change, writes the same
file to the account's config (`<config>/bbd-apparatus/allowed_signers`) and refuses to
install when it has none to write.

The plugin is the same on both channels; which channel a session runs comes from the
tenant's config and the repository's marker, not from the plugin. A tenant repository
carries `templates/tenant-repo/` as committed: the same bootstrap under `.claude/hooks/`
with the signers file beside it, settings that run it on every event and register this
marketplace with auto-update on, the `/read-draft` stub for a cloud session, and the
vault marker, whose tenant provisioning fills. The one-command installer that does all of
this for every account home on a machine is the next change.

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

The keep-current notices compare a session against `data/models.json` (the model
lineup, with release dates and context windows) and `data/claude-code.json` (the latest
Claude Code version). Both are updated by a pull request here, never by a network call
at session start, so every tenant learns of a newer model or version at the turn after
the change lands on their channel.
