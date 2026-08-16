# Phase 8 Follow-ups — Design

Closing the four local gaps Phase 8 (PR #59) recorded and deliberately deferred.
`deploy/README.md`'s "Known gaps carried forward" and `.claude/memory/HANDOFF.md` are the
source list.

---

## 1. Scope

**In:** four independent fixes, each landable and revertible alone.

| id | gap | size |
|---|---|---|
| F2 | `make down` never stops MinIO | 1 line + docs |
| F3 | `scripts/aws/up-all.sh` has no confirmation before a billed EKS apply | small guard |
| F4 | two teaching pages describe the deleted kustomize tree | 14 references |
| F5 | `make up` skips running services, so stale Eureka registrations survive an IP change | the design weight |

**Out — and why:** the fifth recorded gap, **`ENV=aws` has never been deployed**, is a phase of
its own. It is blocked on a design decision that
`.claude/memory/decisions/0005-aws-infra-stays-outside-the-umbrella-chart.md` names but does
not make (two release names, or `aws-deploy.sh` no longer disabling infra), it costs real
money, and it cannot be verified without a billed EKS bring-up. Folding it in here would
block four cheap, verifiable fixes behind one expensive unverifiable one. Recorded, not
silently skipped.

### A correction to the recorded list

The gap list says *three* HTML teaching pages are stale. **`service-architecture.html` has
zero references to the deleted tree** — it describes services, not the k8s layout. F4 covers
two files, not three.

---

## 2. F2 — `make down` must stop MinIO

`scripts/infra/up.sh` starts six compose files; `scripts/infra/down.sh:32` stops five,
omitting `minio.yml`. No comment explains the omission; it is an oversight, not a decision.

Add `minio.yml` to the down list, and correct root `CLAUDE.md`, which describes `make down`
as "stops everything (preserves data)".

**The consequence is the point.** Until this lands the repo **cannot produce a genuine cold
start** — a stray MinIO container makes every subsequent `make up` warmer than a real one.
That is why Phase 8's MinIO readiness poll shipped unexercised, and why F2 lands first
(see §6).

---

## 3. F3 — `up-all.sh` must confirm before spending

`scripts/aws/up-all.sh` chains a from-scratch, billed EKS bring-up and currently contains
**zero** `read` prompts. `make nuke` (`Makefile:111`) already establishes the house style:

```bash
read -p "This wipes ALL volumes (MySQL, Mongo, Kafka, Vault). Continue? [y/N] " ans
[ "$ans" = "y" ] || { echo "Cancelled."; exit 1; }
```

**Placement: at the top of the script, not on the Makefile target.** `make aws-all` is not
the only caller — a human running `scripts/aws/up-all.sh` directly must get the same guard.
It must precede every other executable statement.

**Rules:**
- Prompt names what will be created and that it bills.
- `--yes` skips it, for deliberate non-interactive use.
- **A non-TTY stdin REFUSES rather than proceeds.** A billed action must never default to
  yes; the absence of a human is not consent.

---

## 4. F4 — two teaching pages

`docs/k8s-architecture.html` (711 lines, 10 stale refs) and `docs/k8s-eli5.html` (282 lines,
4) describe `k8s/apps/overlays/`, kustomize, and the bootstrap Jobs — all deleted.

These are **teaching artifacts**, so the fix is to make them describe the Helm reality, not
to excise the sections. A learner reading about "the overlay" needs to be taught about the
chart instead, not to find a hole where the explanation was.

`docs/service-architecture.html` is untouched (0 refs).

---

## 5. F5 — heal stale Eureka registrations

### The failure

`scripts/services/start.sh:115-118` skips any service whose PID file names a live process.
Under compose the JVMs run on the **host**, so each registers its host IP with Eureka. After
a network or IP change the processes are still alive — so `make up` skips them — and they
keep serving stale registrations. Symptom: everything looks up, requests fail. It does not
suggest its own cause; it caught an implementer mid-task during Phase 8.

`make restart` (= `down up`) already fixes it, for anyone who knows that is what they need.

### Approach: fold the check into the existing skip branch

**Rejected:** a separate `ensure-fresh.sh` in the `up` chain (mirrors
`mongo-seed-ensure`, but puts two things in charge of "is this service healthy", and misses
`make bootstrap`); and a manual `make svc-heal` (only helps someone who already suspects
drift — which is exactly what the symptom hides).

The bug is that **one decision is made with incomplete information**, so the fix belongs at
that decision, not beside it. `start.sh`'s skip branch is the single place `up`, `bootstrap`
and `svc-start` all route through.

### The comparison

Read each instance's `ipAddr` from `http://localhost:8761/eureka/apps`
(`Accept: application/json`). Derive the current host IP from the **default-route
interface** — never a hardcoded one:

```bash
iface=$(route -n get default | awk '/interface:/{print $2}')
ip=$(ipconfig getifaddr "$iface")
```

This machine is the proof: its IP is on `en1`, and `ipconfig getifaddr en0` returns empty. A
check hardcoding `en0` would read empty here and bounce every service on every `make up`.

### Stale means registered AND disagreeing

| condition | action |
|---|---|
| registered, `ipAddr` ≠ current | **restart that service** |
| registered, matches | skip (today's behaviour) |
| not registered (frontend, still booting) | skip |
| Eureka unreachable | skip the check entirely |
| current IP undeterminable | skip the check entirely |

The last two carry the most risk. Eureka is tier 1, so it may not be up when `start.sh`
reaches the first services, and **an empty query result must never read as "nothing matches,
restart everything"**. That inversion has landed nine times in this project, several times
inside guards written to prevent it; here it would bounce all nine services on every
`make up` — the exact opposite of the goal.

### Reporting

A restart logs the drift it acted on — `registered 192.168.0.103, host now 10.0.0.7` —
because the whole point is that this symptom is silent about its cause.

---

## 6. Verification

**Order matters: F2 lands first**, because it unlocks a test Phase 8 could not run. Phase 8
added a MinIO readiness poll to `deploy/scripts/seed.sh` and never exercised it, precisely
because `make down` left MinIO running so no cold start ever raced it. Once F2 lands,
`make down && make up` tests both.

**F5 gets a testing seam.** Drift cannot be produced on demand without changing networks, so
the comparison takes an override (`HOST_IP_OVERRIDE`) forcing a given "current IP". The
decision table is then directly testable against a fixture Eureka response.

**Assert the fail-safe cases explicitly.** "Eureka unreachable → selects nothing" and "IP
undeterminable → selects nothing" must be asserted as *empty selections*, not inferred from
"no restarts happened" — a correct empty selection and a broken check are indistinguishable
from outside.

Live: two consecutive `make up` runs on an unchanged network restart nothing; an overridden
run restarts exactly the drifted set.

**F3 must not be tested by running it.** The refusal path *is* safe to exercise (empty stdin,
non-TTY, expect non-zero) — but only after **reading** the script to confirm the guard
precedes every other statement. If it does not, the test itself spends money. `--yes` is
verified by reading, never by execution.

**F4 has no automated test.** Grep proves the stale references are gone; it cannot answer
"does this still teach the right thing", so the pages get read.

---

## 7. Risks

- **F2 changes what `make down` does.** Anyone relying on MinIO surviving a `down` loses
  that. Data persists in the volume, so the cost is a slower next `make up`, not data loss.
- **F5 touches the daily loop.** A wrong staleness verdict either bounces services
  needlessly or misses real drift. The fail-safe rules make the failure mode "does nothing"
  rather than "restarts everything", which is the right direction to be wrong in.
- **F5's Eureka query adds a call to every `make up`.** Bounded by a short timeout; on
  timeout the check is skipped, not retried.
- **F3 could break automation** that calls `up-all.sh` non-interactively. Nothing in this
  repo does; `--yes` covers anyone who does.

## 8. Out of scope, recorded

- `ENV=aws` has never been deployed (§1).
- `fetch-seed-images.sh` was deleted with no replacement; `docker/seed-images/` can be
  consumed but not regenerated. Documented in its README.
- Four frozen oracles cannot regenerate — that is by design, not a gap.
