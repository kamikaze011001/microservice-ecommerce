---
name: a-gaps-registry-decays-through-success
description: deploy/README.md's "Known gaps carried forward" section went stale three times in one branch, because every task closed one of its bullets and no task's brief ever named that file
metadata: { type: convention, date: 2026-08-16 }
---

`deploy/README.md` keeps a **Known gaps carried forward (raised, not fixed)** section. The
Phase 8 follow-ups branch existed to close exactly those bullets — and left the section wrong
three separate times:

1. Task 1 fixed `make down`/MinIO; the bullet still said it was open.
2. Task 4 added the `up-all.sh` confirmation; its bullet still said there was none.
3. Task 3 made `make bootstrap` heal stale registrations; the bullet still said it
   "doesn't detect or fix it".

Each task's brief listed the files its own fix touched. That file was never one of them.

**A registry of known problems only decays through *success*** — the list is wrong precisely
when the work goes well, and nothing in a task-scoped brief points at it.

There is a second-order effect: once both bullets were resolved, the section's **framing**
went stale too. A heading reading "raised, not fixed, in this phase" makes no sense above an
empty list.

**A nuance worth copying from #3:** the bullet's headline ("`make bootstrap` never
force-restarts already-running services") was still *literally true* — the fix heals only
drifted services and deliberately never force-restarts everything. Only the sentence after it
was false. A plain "Resolved" stamp would have been wrong in the opposite direction, implying
bootstrap now bounces everything. It was marked **"Partially resolved"** with the distinction
spelled out.

**How to apply:** when a plan systematically closes items from a list, give that list an owner
in the plan — a task, or a step in the last task. Do not rely on the task that closes a bullet
to notice the bullet. And when marking one resolved, check whether the headline and the body
became false *together*; they often do not.
