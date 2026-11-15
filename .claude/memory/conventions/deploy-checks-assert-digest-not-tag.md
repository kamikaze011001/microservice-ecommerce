---
name: deploy-checks-assert-digest-not-tag
description: A rollback/deploy check that compares tag strings passes even when both tags are the same bytes — assert the pod's imageID digest
metadata: { type: convention, date: 2026-10-10 }
---
The first `make devbox-proof` passed 6/6 while proving nothing. It "rolled back" `order-service:ac48ad8` to `:dev`, but the two tags had the same digest: the old `dev` build came from identical inputs, and the Docker cache reproduced it bit for bit. Every check compared the Deployment's image *string*.

**Why:** content-derived tags plus a deterministic build make "different tag, same bytes" the normal case, not an edge case. A tag-string assertion can't tell the difference.

**How to apply:**
- A check that "version X is running" reads `.status.containerStatuses[].imageID` from the pods and compares it with the registry digest of X (`Docker-Content-Digest`).
- A rollback test first asserts the target is *different bytes*. If not, it derives a distinct image (the same image plus a label).
- Same family as [[mockito-strict-stubs-make-expect-throw-tests-false-green]] and [[key-equals-value-config-hides-key-vs-topic-bugs]]: the check must be able to fail. Related: [[0011-devbox-local-gitops-platform]].
