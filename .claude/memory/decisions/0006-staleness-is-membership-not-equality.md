---
name: 0006-staleness-is-membership-not-equality
description: the Eureka freshness check asks whether the registered address is one this host owns, not whether it equals a single address we compute — because our selection method and Spring's are different functions
metadata: { type: decision, date: 2026-08-16 }
---

`scripts/lib/eureka.sh`'s `eureka_staleness()` reports STALE when Eureka's registered `ipAddr`
is **not a member of** the set `local_host_ipv4s()` returns. It does **not** compare against a
single computed address.

**Why:** the original check used the **default-route** address. Spring registers whatever
`InetUtils` picks — the first non-loopback site-local by interface enumeration order. Two
different selection methods, agreeing on this host by luck: it has five non-loopback IPv4s
(`192.168.0.103` on en1, plus four docker/minikube bridges).

A disagreement would have been a **non-empty wrong** answer. Every fail-safe in that code
guards against *empty* — none against *wrong* — so the result was permanent: every service
declared stale on every `make up`, restarted, re-registering the same address, forever.

Membership deletes the premise instead of widening a tolerance. We stop predicting which
address Spring chose and ask whether its answer is plausible for this machine — answerable
without knowing `InetUtils`' algorithm at all.

**Accepted cost:** the check is deliberately *less eager*. A stale registration whose old
address is still assigned on some other interface now reads as fresh. `make svc-restart`
remains the unconditional remedy. The scenario the feature exists for still trips it — a
network change reassigns the interface to a new subnet, so the old address is owned by no
interface.

*Rejected:* replicating `InetUtils`' selection algorithm — couples the script to Spring
internals that can change under us, and returns to comparing one guess against another.

**How to apply:** do not "simplify" this back to equality; it looks tighter and reintroduces
the coupling. Note also that **a check that never fires satisfies every test in this suite** —
all but one case asserts the not-stale direction, so loosening the predicate makes the suite
greener, not redder. Judge changes here on the merits, not on the test result. Related:
[[a-test-may-exercise-code-production-never-calls]].
