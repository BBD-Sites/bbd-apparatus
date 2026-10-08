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

One command per machine, from a checkout of this repository, naming every account home
on it (an account home is the directory that holds `.claude`):

```
git clone --branch stable https://github.com/BBD-Sites/bbd-apparatus.git
bash bbd-apparatus/install/install.sh --home "$HOME" [--home DIR ...] \
    --tenant <id> --channel stable --token-file <file>
```

The token is read from the file, or from stdin with `--token-file -`, and is never typed
as an argument, printed or logged; the summary shows six hex digits of its sha256. Per
home, with that home's `HOME` and config, the installer refuses a `.claude` that is inside
a git work tree (where `tenant.env` could be tracked); runs the redactor self-test from
the checkout and stops if it fails; copies `plugin/allowed_signers` to
`<home>/.claude/bbd-apparatus/allowed_signers`, and installs nothing while that file is
missing or empty; adds the marketplace by its https URL and installs
`bbd@bbd-apparatus` at user scope, then checks that `enabledPlugins` says so; sets
`autoUpdate` on the marketplace's entry in the home's settings; and writes
`<home>/.claude/bbd-apparatus/tenant.env` (0600, in a 0700 directory) with `BBD_TENANT`,
`BBD_TOKEN` and `BBD_CHANNEL` (`next` for the maintainers, `stable` for every tenant).
One line per home says installed, or refused and why, and the command exits non-zero if
any home was refused. A second run changes nothing and says so. `--uninstall --home DIR`
reverses the enablement, removes the marketplace, `tenant.env` and the signers copy, and
leaves the vault repository, the checkout and the queue alone.

A home that must never carry the apparatus is listed, one absolute path per line, in
`<config>/bbd-apparatus/excluded-homes` of the login that runs the installer (`<config>`
is `$CLAUDE_CONFIG_DIR`, else `~/.claude`). The installer refuses that home, and any home
under it, in every run, install or uninstall, whatever the command line names. The
record stands between runs, which a flag that has to be retyped does not.

The marketplace is this repository (`.claude-plugin/marketplace.json`, name
`bbd-apparatus`); the plugin is `plugin/` (name `bbd`, so its id is `bbd@bbd-apparatus`
and its skills are `/bbd:read-draft` and the four `/bbd:notices-stop-<kind>` stops). The
two `claude plugin` commands the installer runs (`marketplace add`, then `install
bbd@bbd-apparatus --scope user`) work by hand too, but by hand nothing writes the
signers copy or `tenant.env`, so the launcher ships nothing from that home: the installer
is the install. The paste-one-line delivery, where a claim code stands in for the token,
waits on the token exchange (the store, task 3.1 and after); until then the token is a
file the maintainers hand over.

The plugin carries the maintainers' public key (`plugin/allowed_signers`), and the
launcher runs no channel head that key did not sign (`docs/channels.md`). The plugin is
the same on both channels; which channel a session runs comes from the tenant's config
and the repository's marker, not from the plugin. A tenant repository carries
`templates/tenant-repo/` as committed: the same bootstrap under `.claude/hooks/` with
the signers file beside it, settings that run it on every event and register this
marketplace with auto-update on, the `/read-draft` stub for a cloud session, and the
vault marker, whose tenant provisioning fills.

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
