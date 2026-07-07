---
name: consistency-loop
description: >
  Use to close app↔Storybook consistency drift as a reviewed PR. Runs a four-role pipeline —
  implementer → hard gate → blind reviewer → approver → PR — over the frontend. Never
  auto-merges; every run ends at a PR a human merges. Trigger phrases: "consistency loop",
  "consistency sweep", "check design consistency", "/consistency-loop".
---

# Consistency loop — the four-role agent pipeline

**Announce at start:** "I'm using the consistency-loop skill to run one consistency pass."

You (this session) are the **orchestrator + approver**. You dispatch *separate* subagents for
the implementer and the blind reviewer, run the hard gate yourself, and decide the outcome.
Human is *on* the loop: the output is always a PR a human merges. You NEVER auto-merge.

## Preconditions (check first, stop if unmet)
1. On a feature branch off `main` (not `main` itself). If on `main`, create one:
   `git checkout -b consistency/sweep-$(date +%Y%m%d)`.
2. Working tree clean (`git status --porcelain` empty). If dirty, stop and tell the user.
3. `gh auth status` succeeds (needed to open the PR).

## Inputs
- A **scope**: either specific target files, or "scan `frontend/src` for drift" if none given.

## The pass (cap = 3 iterations)

Repeat up to **3 times**:

**① Dispatch the IMPLEMENTER subagent** (fresh `general-purpose`, has Edit/Bash):
> You make the frontend consistent with the design-system SSOT. First invoke the
> `/design-kit` skill to load the SSOT (tokens, primitives, foundations). Scope: <scope>.
> On iteration ≥2, also fix these reported problems: <gate output + blocking findings>.
> Edit the `.vue`/`.ts`/`.stories.ts` files in place. Do NOT commit — leave changes in the
> working tree. Do NOT touch `tokens.css`, `check-consistency.sh`, or CI. Report what you changed.

**② Run the HARD GATE yourself (Bash), FIRST:**
```bash
cd frontend && pnpm check:consistency
```
- Non-zero exit → capture the output, go back to ① (unless at cap → escape hatch).
- Zero exit → continue to ③.

**③ Dispatch the BLIND REVIEWER subagent — FRESH, read-only, NEVER a fork.**
Use the `Explore` subagent type (Read + Bash, no Edit) so it cannot alter the diff and has no
access to the implementer's reasoning:
> You are the blind reviewer. Run `git diff` to see the changes. Read the rubric at
> `.claude/skills/consistency-loop/rubric.md` and the foundations under
> `frontend/src/design-system/foundations/`. Emit findings in the rubric's format, or
> `NO FINDINGS`. Report only — do not decide.

**④ APPROVER decision (you decide):**
| Reviewer result | Action |
|---|---|
| `NO FINDINGS` or advisory-only | **Go** → commit + open PR (below). |
| Any `[blocking]` finding, iterations < 3 | Back to ① with the blocking findings. |
| Still blocking at iteration 3 | **Escape hatch** → draft PR + `needs-human` (below). |

## Go — open the PR
```bash
git checkout -b consistency/fix-<short-slug>   # if not already on a dedicated branch
git add -A && git commit -m "fix(frontend): consistency-loop — <what changed>"
git push -u origin HEAD
gh pr create --base main --title "fix(frontend): consistency-loop — <slug>" --body "<body>"
```
PR body MUST contain: what drifted, what the implementer changed, the gate result (green),
and any **advisory** findings verbatim so the human sees them. Then report the PR URL and stop.

## Escape hatch — stuck at cap
```bash
git add -A && git commit -m "wip(frontend): consistency-loop stuck at cap — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: consistency-loop needs human — <slug>" \
  --body "<gate output + the unresolved blocking findings + what was tried each iteration>"
gh pr edit --add-label needs-human
```
Report the draft PR URL and stop. Do NOT keep iterating past the cap.

## Hard rules
- Blind reviewer is ALWAYS a fresh subagent, never a `fork`.
- Gate runs before the reviewer, every iteration.
- Never auto-merge. Never modify `tokens.css`, components' behavior, `check-consistency.sh`, or CI.
- Stop at 3 iterations — no exceptions.
