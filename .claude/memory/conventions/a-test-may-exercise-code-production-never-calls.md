---
name: a-test-may-exercise-code-production-never-calls
description: registration_is_stale() was called only by the suite while start_one() re-implemented the formula inline — the mutation test that "proved the suite can fail" perturbed a function production never ran
metadata: { type: convention, date: 2026-08-16 }
---

`scripts/lib/eureka.sh` exported `registration_is_stale()`. **Only
`scripts/lib/tests/eureka-test.sh` called it.** `start_one()` in
`scripts/services/start.sh` re-implemented the identical formula inline.

The duplication was deliberate and disclosed: `start_one` needed both IPs for its log line,
and calling the function then re-fetching them would double the Eureka round-trip per service
— a defect an earlier review had already caught and fixed.

**The consequence is the part to remember.** A review "proved the suite can fail" by
perturbing `registration_is_stale` and watching the suite go red. That proved nothing about
the shipped path: breaking `start.sh`'s inline copy left the suite at a clean 6/0.

Fixed by making the function return the verdict **and** the values on stdout, which removes
the reason to duplicate it:

```
eureka_staleness <http_port>
  stdout : "<reg_ip> <local_ip…>"   (only on exit 0)
  exit 0 : STALE      exit 1 : not stale, OR unknown (prints nothing)
```

**How to apply:** before trusting a mutation test, check that the mutated symbol is reachable
from production — `git grep` its callers and confirm at least one is not a test. When a caller
duplicates a helper "for one extra value", that is the signal: change the helper to return the
value rather than letting the caller reimplement it.

The general form, and the most transferable thing from this work: **a green result is only
evidence if you know what red would have looked like.** Three times in this repo a check
passed while proving nothing — a suite reading a deleted file, this mutation test, and a grep
gate blind to a diagram. What caught all three was asking what the measurement would show if
the thing measured were absent, then arranging for the answer to differ. Related:
[[an-unguarded-read-passes-when-its-input-vanishes]],
[[a-grep-gate-tests-for-strings-not-for-currency]].
