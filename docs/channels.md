# Channels

`stable` is what every tenant runs. `next` is what the maintainers run first. A change lands on `next` by pull request, runs there for the canary window, and reaches `stable` by a merge, never a cherry-pick. A head on either branch may be signed; the launcher may refuse an unsigned head.
