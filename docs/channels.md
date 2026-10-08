# Channels

`stable` is what every tenant runs. `next` is what the maintainers run first.

A change lands on `next` by pull request, and the pull request is reviewed. It is landed by a fast-forward push of its reviewed head to `next`, made by the maintainers' GitHub App. It is never landed by a merge button or by `gh pr merge` under a person's login. Every merge a person performs through GitHub stamps that person's name or email into the result, and this repository carries no name (design D41).

The rulesets on `next` and `stable` require a pull request, forbid a force push and forbid deletion. They name the App as their only bypass actor.

A change runs on `next` for the canary window. It reaches `stable` the same way: a fast-forward push of `next`'s head, never a cherry-pick.

The launcher refuses an unsigned or wrongly signed head whenever an `allowed_signers` file is present (`docs/launcher-contract.md`, section 3).
