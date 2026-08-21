---
name: branch-ahead-count-measures-divergence-not-value
description: two AWS branches 77 commits ahead of main looked like stranded work and contained nothing main lacked
metadata: { type: convention, date: 2026-08-21 }
---

`feat/aws-deploy` sat 76 commits ahead of `main`, `feat/aws-live-deploy` 1 ahead. Both
read as unfinished work someone should rescue. Comparing **content** rather than
counting commits:

- `feat/aws-deploy`'s Terraform is byte-identical to main's except `aws/main/rds.tf`,
  where **main is the newer, cleaner version**. The remaining commits are kustomize
  deployment tooling that Phase 8 replaced with the Helm cut-over.
- `feat/aws-live-deploy`'s single commit had already reached main by other routes — the
  `sts` dependency in `core/core-s3/pom.xml`, both memory conventions it added, its
  session log, and the substance of its `infra-up.sh` / `up-all.sh` guards.

A branch can be far ahead because its work is unfinished, or because the work was redone
better somewhere else. **The counts are identical in both cases.**

A related trap: `git diff main <branch>` on a branch that is also *behind* shows the
symmetric difference. `feat/aws-live-deploy` reported 388 files and 37,773 deletions —
that is main's Phase 8 deletions reappearing as re-additions. It describes staleness,
not contribution. Use `git log main..<branch>` and `git show <commit>` to see what a
branch actually adds.

**How to apply:** never rank work from ahead/behind counts. Ask "what does it have that
main does not", and answer by checking whether each piece of content exists on main —
not by reading a diff against a stale base.
