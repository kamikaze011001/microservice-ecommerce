---
name: an-unexercised-path-fails-where-nothing-rendered-it
description: five phases of green AWS verification missed a blocker on line 28 of a shell script, because the gates render Helm templates and never execute the scripts
metadata: { type: convention, date: 2026-08-21 }
---

`ENV=aws` shipped through five phases with every offline suite green:
`make aws-diff-test` renders the chart and diffs it against a frozen oracle;
`verb-equivalence` compares `make -n` expansions against baselines. Both pass.

Neither executes `deploy/images/build.sh`, `scripts/aws/push-images.sh`, `infra-up.sh`
or `down.sh`. So a defect that stops step 2 dead
([[a-shared-builder-assumes-its-local-registry]]) was invisible: **the gate and the
defect occupy different universes.** One checks what YAML we would produce; the other is
a shell script that dies before producing anything.

The same blind spot hid a teardown guard gap
([[the-teardown-path-lacks-the-guards-the-creation-path-has]]).

Both were findable for free, in under a minute, by *reading the scripts* — no cluster,
no spend. That is the actionable part: for a path that has never run, a targeted reading
pass is far cheaper than discovering the same bugs at EKS rates, and the offline suites
give no warning that they are not covering it.

**How to apply:** before the first live run of any path, audit it for the class the
suites structurally cannot see — `http://` against remote hosts, hardcoded `localhost`,
`kubectl` with no `--context`, `|| true` over transport failures, unbounded network
calls, a fixed `sleep` standing in for a poll, references to deleted files, and error
messages naming the wrong system. Treat "all suites green" on a never-executed path as
carrying no information about whether it runs. Related:
[[first-install-cannot-verify-a-deploy-path]],
[[0008-unexercised-paths-run-in-checkpoints-not-one-shot]].
