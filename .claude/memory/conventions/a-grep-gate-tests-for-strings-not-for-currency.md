---
name: a-grep-gate-tests-for-strings-not-for-currency
description: a docs task passed `grep -c 'k8s/|kustomize|overlays' → 0` while the page still rendered a diagram of five deleted bootstrap Jobs, because node ids and labels encode architecture without using those words
metadata: { type: convention, date: 2026-08-16 }
---

Task 4 of the Phase 8 follow-ups rewrote two HTML teaching pages that described the deleted
kustomize tree. The completion gate was:

```
grep -cE 'k8s/(apps|infra)|kustomize|overlays' → 0
```

It returned 0 while `docs/k8s-architecture.html` still rendered a `boot` lane containing five
Job nodes — `"01 mysql-seed"`, `"02 mongo-seed"`, `"03 vault-seed"` … — teaching the deleted
5-Job bootstrap **without using any of the gated words**. The implementer found it by reading
the page and flagged it; the gate could not.

A follow-up check was worse: grepping `01-mysql-seed` also returned 0, because the nodes are
written `"01 mysql-seed"` with a **space**.

**Why this shape recurs:** prose about overlays says "overlay". A diagram says
`{id:"jobMysql", nm:"01 mysql-seed", lane:"boot"}` — the architecture lives in identifiers,
labels and structure, not vocabulary. Any gate phrased as "these strings are absent" is
structurally blind to it.

**How to apply:** a grep gate is a useful *finder* and a bad *completion criterion*. For
documentation, the only sufficient check is reading it. If you must automate something, assert
on what should be PRESENT (does the page mention the chart, `make deploy ENV=k8s`?) rather than
only on what should be absent — an absent-string assertion passes when the content is missing,
wrong, or written differently, and those are not the same outcome.

Corollary from the same task: line counts guarded against the other failure mode, achieving
"0 stale references" by **deleting** the sections. 711→717 and 282→282 showed rewriting, not
excision. Related: [[a-test-may-exercise-code-production-never-calls]],
[[make-n-shows-commands-not-the-files-they-read]].
