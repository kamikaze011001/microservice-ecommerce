---
name: decomposing-a-wrapper-drops-what-it-did-besides-calling-steps
description: running up-all.sh's nine steps individually lost its PUSH default and its Step 0 env preflight, twice, because a wrapper's own contribution is exactly what decomposition makes invisible
metadata: { type: convention, date: 2026-08-28 }
---

The first live AWS run deliberately called `scripts/aws/up-all.sh`'s nine steps
individually rather than running the orchestrator, to get a checkpoint after each
failure domain ([[0008-unexercised-paths-run-in-checkpoints-not-one-shot]]). That
was the right call and it still cost twice:

1. **`PUSH` vs `svc`.** The plan said `PUSH=all make aws-push`. `PUSH` is read *only*
   by `up-all.sh:61`. `Makefile:817` passes `$(svc)`, and `push-images.sh:36` defaults
   `TARGET` to `gateway` — so it pushed one service out of ten, and the stale tags
   pulled fine, so it would have degraded silently three checkpoints later.
2. **The Step 0 preflight.** `up-all.sh:97-112` runs four `need` checks for
   `PAYPAL_CLIENT_ID/SECRET` and `APPLICATION_MAIL_USERNAME/PASSWORD`, each naming the
   file to fill. Calling `secrets-seed.sh` directly skipped them, so an unset variable
   surfaced as an opaque resolver error mid-run instead of a clear message at the door.

**The pattern:** an orchestrator is not just a sequence of calls. It is that sequence
*plus* its preflight, its env defaults, and any state it establishes (here, step 1's
`update-kubeconfig` setting the ambient context every later step relies on). The steps
are easy to enumerate — they have names and numbers. The wrapper's own contribution
appears in no step's definition, which is precisely what makes it invisible when you
decompose.

**How to apply:** before running a wrapper's steps individually, read the wrapper
top-to-bottom and list everything it does that is *not* a call to a step. Port those
into the decomposed procedure explicitly. Grep the wrapper for env-var reads
(`${VAR:-`), guard functions, and anything before the first step banner.

Related: [[an-oracle-can-validate-a-command-nobody-runs]] — both are failures of
"the thing I verified is not the thing that runs".
