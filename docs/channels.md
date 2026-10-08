# Channels

`stable` is what every tenant runs. `next` is what the maintainers run first.

A change lands on `next` by pull request, and the pull request is reviewed. It is landed by a fast-forward push of its reviewed head to `next`, made by the maintainers' GitHub App. It is never landed by a merge button or by `gh pr merge` under a person's login. Every merge a person performs through GitHub stamps that person's name or email into the result, and this repository carries no name (design D41).

The rulesets on `next` and `stable` require a pull request, forbid a force push and forbid deletion. They name the App as their only bypass actor.

A change runs on `next` for the canary window. It reaches `stable` the same way: a fast-forward push of `next`'s head, never a cherry-pick.

## Signed heads

Every head pushed to `next` or `stable` is signed by the maintainers' key. Its public half ships with the plugin as `plugin/allowed_signers`, and as `.claude/allowed_signers` in the tenant repository template for the committed copy, and the launcher verifies every fetched head against that file before the checkout moves (`docs/launcher-contract.md`, section 3, step 5). A head the key did not sign is never checked out and never run, so a push by anyone but the holder of the key reaches no tenant, whatever the push carries. The private key lives with the maintainers alone: never in this repository, never in an Actions secret, never on a tenant's machine.

Whoever lands a pull request verifies before the fast-forward push, with the launcher's own command:

```
git -c gpg.ssh.allowedSignersFile=plugin/allowed_signers verify-commit <head>
```

It must print a good signature for the head being pushed. The test workflow runs the same check on every pull request into a channel and on every push to one, and goes red on an unsigned or wrongly signed head. Every commit of a pull request is signed, not only its tip, so any earlier commit of it can be fast-forwarded on its own and still verify.

A rebase makes new commits, and a new commit needs a new signature. Rebase with the signing options set, which signs each commit it re-creates:

```
git -c gpg.format=ssh -c user.signingkey=<private key file> -c commit.gpgsign=true \
    -c user.name='apparatus maintainers' \
    -c user.email='apparatus-maintainers@users.noreply.github.com' rebase <base>
```

or re-sign after the fact with `git rebase --exec 'git -c gpg.format=ssh -c user.signingkey=<private key file> commit --amend --no-edit -S' <base>`. The identity stays the neutral one on every commit (design D41); the author's date and message are kept.
