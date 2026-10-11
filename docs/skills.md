# The buyer's skills

Four skills run in the owner's own session, on the owner's own plan. Each is a stub in the
plugin (`plugin/skills/NAME/SKILL.md`) and in the tenant repository
(`templates/tenant-repo/.claude/skills/NAME/SKILL.md`, so a cloud session has them too),
except `plan`, which stays out of the tenant repository while it is gated (below). A
stub carries no instructions. It runs `skill NAME` through the bootstrap, and the launcher's
skill event (`launcher/events/skill.sh`) prints the text in `text/skills/NAME.md` from the
checkout, so a skill changes here and never in the plugin.

| Skill | What it does |
| --- | --- |
| `intake` | Asks who the owner is, how to talk to them, their faith, and which areas of life go in (every one offered, none required). Writes `RULES.md`, `40-areas/<name>/README.md` (with the tier) and `30-projects/<name>.md`, and reads them back. Run again, it adds one area and touches nothing else. |
| `plan` | Dump, Today, the weekly review and waiting-on over the repository, with tiers and the five horizons carried at once. To-dos are lines in project pages; the week's Big 3 are `30-projects/plan/week-<date>.md`; the horizons are `30-projects/plan/horizons.md`. Gated by channel, below. |
| `spec-interview` | Turns a conversation into an OpenSpec change, extends an open one before starting a new one (the duplicate-change guard, section 15 of the launcher contract, refuses a second change for the same ground), and keeps the files current. |
| `capture` | Decides, for each piece of a dump, to capture it whole in `00-inbox/`, file it under a project or area, or make it a change (hand-off to `spec-interview`), and does every piece without asking. Routes a file that is not text by size. Sends each research-shaped piece to its own parallel agent when the harness offers agents, and says how many started and where each result lands. A piece that ends in sending, posting, booking or paying becomes a draft in the vault; the owner sends it from their own account. |

## Rules every skill text keeps

Each text has three sections (When to use, Steps, Never), says it sends nothing to anyone,
is plain ASCII, is under 3,500 bytes and grades at or under fifth grade by the Stop gate's
own grader. `tests/test-buyer-skills.sh` holds all of that. `tests/test-never-outward.sh`
reads every text, stub and skill-event output for a sentence that tells the model to send,
post, book, pay, buy, email, text, publish, submit or message, and fails on one; a sentence
that is descriptive goes on `tests/outward-allowlist.txt` with a reason.
`tests/test-quiet-and-no-warning.sh` holds that no shipped file warns about recording or the
law around it (the terms say it once; the apparatus never does), and that no code or hook
here can send the owner a message, a text or a push. The brief is a portal setting that
defaults to never; the `plan` skill says so.

## The contradiction line

`text/witness-rules.md` is injected on every prompt. It carries one line: when what the owner
asks now contradicts something their own record shows they said before, the reply says so
first, in one sentence that quotes the earlier line with its date, then does what was asked.
The scorecard half of that requirement is the platform's, not this repository's.

## Big files

The limit is the number the vault's README states ("A file up to N MB is kept in
`attachments/`"), 25 MB when it states none. The `capture` event prints that limit, in bytes,
beside where a bigger file stays: the owner's own store by default, their Google Drive folder
only when `.apparatus/storage.json` says `{"drive": true}`. The model compares sizes itself;
nothing is asked of the owner. `lib/skillinfo.py place` makes that block.

## The planning gate

`data/skill-gates.json` lists, for a gated skill, the channels it is open on. It ships
`{"plan": ["next"]}`: the planning loop is not offered to a buyer until the operator has run
four weekly reviews on it (planning-loop requirement). A missing or broken file closes it
everywhere. Three locks hold it shut for a buyer on `stable`:

- The tenant template (`templates/tenant-repo/.claude/skills/`) has no `plan` stub, so a
  buyer's vault never gets one.
- The plugin's `plan` stub sets `disable-model-invocation: true` and has a description with
  no trigger words, so the model cannot pick it by description on any channel. It is reached
  by name only, which is how tenant zero runs it on `next`.
- The skill event prints nothing for `plan` on a channel the gate does not open.

Opening it on `stable` is one signed edit that does two things: it adds `stable` to
`data/skill-gates.json`, and it adds the `plan` stub back to the tenant template (with its
trigger description, and without `disable-model-invocation`, in the plugin too). The manifest
test expects the template to carry every plugin stub except the ones named in the gate file,
so it fails until both halves are done.

## Not built

- The big-file upload itself. The skill makes the page, names the file and where it stays, and
  says the upload waits. The resumable upload to the store, and the Drive upload, are the
  platform's (large-files requirement) and nothing here does them.
- Nothing writes `.apparatus/storage.json` yet. The portal's Drive connection is expected to.
  Until it does, every big file is routed to the store, which is the default.
- The scripture shelf. The intake records the owner's faith and their yes to the shelf in
  `RULES.md` and `70-library/scripture/README.md`; placing the works is the library task.
- The count of settings that fit one dashboard screen, and the proof on the operator's own
  repository and then on a first buyer.
