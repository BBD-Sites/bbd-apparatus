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
