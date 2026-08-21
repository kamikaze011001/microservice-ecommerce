---
name: errexit-consumes-a-functions-exit-code
description: under set -e a bare call to a function that signals via exit codes aborts the script before the caller can read $?, silently collapsing a multi-code contract into one silent exit
metadata: { type: convention, date: 2026-08-21 }
---

`scripts/aws/down.sh` runs under `set -euo pipefail`. A guard was added returning three
distinct codes — 0 reachable, 1 context absent, 2 cluster not answering — because each
needs a different operator response. The caller was written as:

```bash
require_kube_context "$EKS_CONTEXT"
case $? in
  0) ... ;; 1) ...diagnostic...; exit 1 ;; 2) ...diagnostic...; exit 1 ;;
esac
```

**Every diagnostic in that block is unreachable.** Under `errexit` a bare non-zero
return aborts immediately, before `case` runs. Verified with a stub returning 2:

```
before guard
  --> exit=2          # the case never executed
```

The fix keeps the failure *handled* rather than fatal:

```bash
rc=0
require_kube_context "$EKS_CONTEXT" || rc=$?
case $rc in ... esac
```

**Why it is worth remembering:** the bug being fixed was `|| true` merging "nothing to
delete" with "couldn't reach the cluster". The fix introduced three codes to keep them
apart — then collapsed all three back into one silent exit, one layer up. The safety
property survived (nothing was destroyed), so it looked fine; only the operator's
ability to know *why* was lost.

It also passes every cheap check. `bash -n` is clean, the unit suite is green, and
`grep` finds the code present. Nothing short of executing the branch reveals it.

**How to apply:** in any `set -e` script, a function that communicates through exit codes
must be called where failure is handled — `|| rc=$?`, an `if`, or `&&`/`||`. Never
bare-then-`$?`. And when adding such a guard, prove each branch is reachable by stubbing
the function to every return value and watching for the message; never infer it from a
passing suite. Related: [[a-test-may-exercise-code-production-never-calls]],
[[the-teardown-path-lacks-the-guards-the-creation-path-has]].
