---
name: refactor-first-is-an-ordering-constraint
description: a plan ordered "change the semantics, then unify the duplicate" was not merely awkward but impossible — the unification is what creates the single site the semantic change lands in
metadata: { type: convention, date: 2026-08-16 }
---

The Eureka hardening plan had two tasks: change the staleness comparison from equality to
membership, and collapse a duplicated formula into one function. It was written with the
semantic change first, as "two independent follow-ups".

The SDD pre-flight scan found the order was **impossible**, not just untidy:

- `start_one()` **inlined** the equality formula, so with two copies there was no single site
  at which to change the semantics. Membership-first would have had to edit both — which is
  exactly the work the unification exists to remove.
- It also removed `current_host_ip()` while `start.sh` still called it. That degraded safely
  (`|| _host_ip=""` catches a missing function → reads not-stale) rather than crashing, but
  one commit on the branch would have shipped the feature silently disabled, printing
  `command not found` per service.

Reordered to unify first (commit `30d7081`), both task bodies re-derived for their new
dependencies. Every commit then stayed independently correct.

**How to apply:** when a plan pairs a refactor with a behaviour change to the same logic, the
refactor is not a tidy-up that happens to come first — it **creates the place the change
happens**. Check for the dependency explicitly by asking *who calls what*, because a spec
describing them as "two independent fixes" (this one did) will not reveal it.

The generalisation that caught it: a pre-flight scan should trace call sites, not just read
task descriptions. This dependency was invisible in prose and obvious in one `git grep`.
Related: [[a-test-may-exercise-code-production-never-calls]] — the same duplication, seen from
the testing side.
