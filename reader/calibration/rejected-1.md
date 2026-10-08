[site: contact form]

I spent some time digging into this. First I checked the deploy logs in PR 212 and then traced the request path through the serving layer, which took a while because the staging environment had drifted from production and I had to reconcile the two configs before I could reproduce anything reliably.

The root cause is that the form's POST endpoint was still pointing at the legacy ingress on the old host, so every submission was returning a 301 that the browser followed as a GET, which the endpoint rejects with a 405 and the page swallows silently. I fixed it in commit 4f1c2aa by updating the action attribute and verified via curl that submissions now return 200. I also noticed the analytics snippet was loading twice and fixed that while I was in there, and filed #233 for the stale staging config.

Your form has been broken since the host move on the 14th, so roughly 11 messages were probably lost.

Let me know if you want me to look at anything else - happy to help.
