# Consistency Loop Phase 2 (Agent Pipeline) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Exception:** Task 5 (the manual proof run) must run *inline* in the orchestrating session — it invokes `/consistency-loop`, which itself dispatches subagents, so it cannot be delegated to another subagent.

**Goal:** Ship the `/consistency-loop` skill — a four-role agent pipeline (implementer → hard gate → blind reviewer → approver → PR) that proposes app↔Storybook consistency fixes for human review, and prove it manually on one real inconsistency.

**Architecture:** The main Claude Code session is a thin orchestrator + approver. It dispatches *separate* subagents for the implementer and the blind reviewer, and runs Phase 1's `check-consistency.sh` itself via Bash. The blind reviewer is a fresh, read-only subagent (never a `fork`) that sees only the diff + the SSOT + a rubric, so it forms an independent judgment. Every path ends at a PR a human merges — never auto-merge.

**Tech Stack:** Claude Code skills (Markdown + frontmatter), the Agent tool (subagent dispatch), `gh` CLI, Phase 1's `frontend/scripts/check-consistency.sh` (`pnpm check:consistency`), the existing `/design-kit` skill (SSOT context).

## Global Constraints

- **Blind reviewer = a FRESH subagent, NEVER a `fork`.** A fork inherits the implementer's reasoning and rubber-stamps. Dispatch it via the Agent tool with a fresh (non-fork) subagent type.
- **The hard gate runs FIRST**, before any LLM review — no review is spent on code that doesn't lint or is missing a story.
- **Cap the loop at 3 implementer↔gate↔reviewer passes.** On the 3rd failure, open a `--draft` PR labelled `needs-human` instead of grinding.
- **NEVER auto-merge.** Every path ends at a PR a human merges.
- **Reuse, don't rebuild:** Phase 1's `frontend/scripts/check-consistency.sh` and the `/design-kit` skill are used as-is. Do not modify them, `tokens.css`, or any component.
- **Skill files live under** `.claude/skills/consistency-loop/`. Frontmatter is `name:` + `description:` (match the existing `.claude/skills/save-memory/SKILL.md` convention).
- **The gate is invoked as** `cd frontend && pnpm check:consistency` (exits non-zero on violation).
- **The implementer leaves changes UNCOMMITTED** in the working tree; only the orchestrator/approver commits, after approval.

---

### Task 1: Skill scaffold + `needs-human` GitHub label

**Files:**
- Create: `.claude/skills/consistency-loop/` (directory)
- Create: `.claude/skills/consistency-loop/.gitkeep` (placeholder so the empty dir commits; deleted in Task 2)

**Interfaces:**
- Produces: the `.claude/skills/consistency-loop/` directory that Tasks 2–3 write into; a repo label `needs-human` that Task 3's escape hatch references.

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p .claude/skills/consistency-loop
touch .claude/skills/consistency-loop/.gitkeep
```

- [ ] **Step 2: Create the `needs-human` label**

```bash
gh label create needs-human \
  --description "Consistency-loop stuck at cap — needs a human to finish" \
  --color D93F0B
```
Expected: `✓ Label "needs-human" created`.
If it already exists (`already exists` error), that is fine — continue.

- [ ] **Step 3: Verify the label exists**

```bash
gh label list | grep -i needs-human
```
Expected: a line containing `needs-human`.

> Note: `gh label create` is a write to GitHub. If the harness gates it for review, ask the user to run the command shown, then re-run Step 3.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/consistency-loop/.gitkeep
git commit -m "chore(skills): scaffold consistency-loop skill + needs-human label"
```

---

### Task 2: The rubric (`rubric.md`)

**Files:**
- Create: `.claude/skills/consistency-loop/rubric.md`
- Delete: `.claude/skills/consistency-loop/.gitkeep` (no longer needed)

**Interfaces:**
- Consumes: the skill directory from Task 1.
- Produces: `rubric.md` — the blind reviewer's grading criteria. Task 3's reviewer dispatch prompt references it by relative path `.claude/skills/consistency-loop/rubric.md`. Each item is tagged `[blocking]` or `[advisory]`; the reviewer returns findings keyed to these numbers.

- [ ] **Step 1: Write the rubric file**

Create `.claude/skills/consistency-loop/rubric.md` with exactly this content:

````markdown
# Consistency rubric — Issue Nº01

You are a **blind reviewer**. You have been given a `git diff` and the design-system
foundations. You did NOT see how the diff was produced and must not assume it is correct.
Grade the diff against the checks below. For each violation, emit one finding:

```
- [blocking|advisory] #<check-number> <file>:<line> — <what's wrong, one sentence, cite the rule>
```

If the diff is clean, emit exactly: `NO FINDINGS`.
Report only. Do NOT decide what happens next — the approver does that.

Ground every judgment in the foundations you were given
(`frontend/src/design-system/foundations/*.mdx`, `guides/CopyVoice.mdx`). If a check needs
context the diff doesn't show, read the surrounding file — do not guess.

## Checks

**#1 Stamps, not badges — [blocking]**
Status (PAID / PROCESSING / CANCELED / SOLD OUT, etc.) must render via `<BStamp>` — a
double-ring border, condensed mono, `--stamp-red`, slight rotation. A rounded pill/badge
for status is a violation. Source: Foundations/Identity, Foundations/Signature Details.

**#2 Spot discipline — [blocking]**
`--spot` (`#FF4F1C`) is for *every* CTA, focus ring, and alert — and nothing else visually
competes with it. `--stamp-red` (`#C4302B`) is for stamps and validation borders ONLY, never
a CTA. No fourth/fifth colour may appear without a token in `tokens.css` + an ADR. Source:
Foundations/Color.

**#3 Shadow language — [blocking]**
Shadows are hard offset only — no blur, no opacity. Use the shadow ladder
(`--shadow-sm` 3px, `--shadow-md` 6px, …). A `box-shadow` with a blur radius or rgba alpha
is a violation. Source: Foundations/Borders & Shadows.

**#4 Primitive intent — [blocking]**
Reuse the `B*` primitives; do not re-implement a primitive's look inline. The Phase 1 gate
already bans raw `<button>/<input>/<select>` outside `primitives/`; this check catches the
subtler case — e.g. a `<div>` styled to *look* like a `BButton`/`BStamp` instead of using
the component. Source: Foundations/Identity.

**#5 Signature details in place — [advisory]**
Where the layout calls for them, the signature details should be present: misregistration
`text-shadow: 2px 2px 0 var(--spot)` on product-card titles on hover; ±0.5° sticker rotation
on product cards; `<BCropmarks>` instead of `<hr>`; `<BMarginNumeral>` for big section
numerals. Flag a spot where one is conspicuously missing. Source: Foundations/Signature Details.

**#6 Story completeness — [advisory]**
If the diff touches a component, its `*.stories.ts` should show all of that component's
variants/states, not just one. The Phase 1 gate only checks the story *exists*. Source:
Guides/Components.

**#7 Copy voice — [advisory]**
Copy is printer-shop deadpan: present-tense declarative; Title Case for CTAs and stamps;
mono font for IDs/prices/timestamps; SCREAMING CAPS for numerals/section headers; never
sentimental ("Oops!", "Whoops!", "We're sorry but…"). Prefer the copy bank in
Guides/CopyVoice (e.g. empty cart = "Your cart is empty. Browse the lots."). Source:
Guides/CopyVoice.

## Severity → what the approver does with it
- Any **[blocking]** finding → the diff goes back to the implementer.
- **[advisory]** findings only → the PR proceeds, with the advisories listed in its body.
````

- [ ] **Step 2: Remove the scaffold placeholder**

```bash
rm .claude/skills/consistency-loop/.gitkeep
```

- [ ] **Step 3: Structural verification of the rubric**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
grep -c '^\*\*#' .claude/skills/consistency-loop/rubric.md   # expect 7 (seven checks)
grep -c '\[blocking\]' .claude/skills/consistency-loop/rubric.md   # expect >=4
grep -q 'NO FINDINGS' .claude/skills/consistency-loop/rubric.md && echo "clean-signal OK"
```
Expected: `7`, a number `>= 4`, and `clean-signal OK`.

- [ ] **Step 4: Behavioural check — reviewer flags a planted violation (agent-run acceptance check)**

This verifies the rubric actually drives a blind reviewer to the right finding. It is an
agent-run qualitative check, not a scripted test.

1. Create a throwaway fixture diff (do NOT commit):

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce/frontend
cat > /tmp/consistency-fixture.vue <<'EOF'
<template>
  <!-- BAD: status shown as a rounded pill badge instead of <BStamp> (rubric #1) -->
  <span class="badge">PAID</span>
</template>
<style scoped>
.badge { border-radius: 9999px; background: var(--spot); color: var(--paper); padding: 4px 10px; }
</style>
EOF
```

2. Dispatch a FRESH read-only subagent (the `Explore` type — it has Read + Bash but cannot
   Edit, which matches the reviewer's read-only role) with this prompt:

```
You are the blind reviewer. Read the rubric at
.claude/skills/consistency-loop/rubric.md and the foundations under
frontend/src/design-system/foundations/. Review this diff:

  <paste the contents of /tmp/consistency-fixture.vue as an added file>

Emit findings in the rubric's format, or NO FINDINGS.
```

Expected (qualitative): the subagent returns a `[blocking] #1` finding — status as a badge,
not `<BStamp>`. If it returns `NO FINDINGS` or misses #1, the rubric wording needs tightening;
revise Step 1 and re-run.

3. Clean up: `rm /tmp/consistency-fixture.vue`

- [ ] **Step 5: Commit**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
git add .claude/skills/consistency-loop/rubric.md .claude/skills/consistency-loop/.gitkeep
git commit -m "feat(skills): consistency-loop rubric (blind reviewer criteria)"
```

---

### Task 3: The orchestrator skill (`SKILL.md`)

**Files:**
- Create: `.claude/skills/consistency-loop/SKILL.md`

**Interfaces:**
- Consumes: `rubric.md` (Task 2); Phase 1's `pnpm check:consistency`; the `/design-kit` skill; the `needs-human` label (Task 1).
- Produces: the `/consistency-loop` skill. Task 5 invokes it.

- [ ] **Step 1: Write the skill file**

Create `.claude/skills/consistency-loop/SKILL.md` with exactly this content:

````markdown
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
````

- [ ] **Step 2: Structural verification of the skill**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
S=.claude/skills/consistency-loop/SKILL.md
grep -q '^name: consistency-loop' "$S" && echo "frontmatter OK"
grep -q 'never a `fork`' "$S" && grep -q 'FRESH' "$S" && echo "blindness rule OK"
grep -q 'pnpm check:consistency' "$S" && echo "gate wired OK"
grep -q 'rubric.md' "$S" && grep -q '/design-kit' "$S" && echo "references OK"
grep -q 'cap = 3' "$S" && grep -q 'needs-human' "$S" && echo "termination OK"
grep -q 'NEVER auto-merge' "$S" && echo "no-automerge OK"
```
Expected: all six `OK` lines print.

- [ ] **Step 3: Discoverability check (agent-run)**

Confirm the skill is loadable: in this session, verify `/consistency-loop` now appears in the
available-skills list (a `<system-reminder>` will list it, or invoking `Skill` with
`consistency-loop` resolves). If it does not resolve, the frontmatter `name` is wrong — fix Step 1.

- [ ] **Step 4: Integration dry-run on synthetic drift (agent-run acceptance check, throwaway)**

This proves the *machinery* end-to-end before Task 5 spends it on real drift. Do it on a
scratch branch you discard — this is a test, not the proof.

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
git checkout -b throwaway/consistency-dryrun
```

Plant one subjective drift the gate cannot catch (e.g. in a small existing component, replace
a `<BStamp>` status usage with a hand-styled `<span>` badge, or introduce sentimental copy
"Oops! Something went wrong." where the copy bank says otherwise). Then run the pipeline
manually per this SKILL.md: dispatch implementer → run gate → dispatch fresh reviewer → apply
the approver table. 

Expected (qualitative): the gate passes (subjective drift is invisible to it), the fresh
reviewer returns the matching `[blocking]` finding, you route back to the implementer, it
fixes the drift, and the second reviewer pass returns `NO FINDINGS`. You do NOT open a real PR
here. Clean up:

```bash
git checkout feat/storybook-consistency-loop-phase2
git branch -D throwaway/consistency-dryrun
```
If any role misbehaves, revise `SKILL.md`/`rubric.md` and re-run.

- [ ] **Step 5: Commit**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
git add .claude/skills/consistency-loop/SKILL.md
git commit -m "feat(skills): consistency-loop orchestrator skill (four-role pipeline)"
```

---

### Task 4: ADR + `frontend/CLAUDE.md` pointer

**Files:**
- Create: `frontend/docs/adr/0008-consistency-loop-agent-pipeline.md`
- Modify: `frontend/CLAUDE.md` (add a pointer under the design-system section)

**Interfaces:**
- Consumes: nothing at runtime — documentation only.
- Produces: the durable decision record; discoverability of the loop from `frontend/CLAUDE.md`.

- [ ] **Step 1: Read the ADR template**

```bash
cat /Users/sonanh/Documents/AIBLES/microservice-ecommerce/frontend/docs/adr/0000-template.md
```
Match its section structure in the next step.

- [ ] **Step 2: Write ADR 0008**

Create `frontend/docs/adr/0008-consistency-loop-agent-pipeline.md`, following the template's
structure, capturing: **Context** (Phase 1 gate closes objective drift only; subjective drift +
manual fixes remain open-loop); **Decision** (a four-role pipeline — separated implementer +
blind-reviewer subagents, orchestrator-run hard gate first, approver opens a PR; blind reviewer
is a fresh subagent, never a fork; cap 3 + `needs-human` escape hatch; never auto-merge; run
manually in Phase 2, triggers deferred to Phase 3); **Consequences** (subjective consistency now
has an owner; every fix is a reviewed PR; cost is per-run subagent tokens; blindness depends on
the fresh-subagent rule holding).

- [ ] **Step 3: Add the pointer to `frontend/CLAUDE.md`**

Under the "Design system — single source of truth" section, append this line after the
"Decisions: `docs/adr/`" bullet:

```markdown
- **Consistency loop:** `/consistency-loop` proposes app↔Storybook consistency fixes as a
  reviewed PR (four-role agent pipeline; hard gate = `pnpm check:consistency`). See
  `docs/adr/0008-consistency-loop-agent-pipeline.md`.
```

- [ ] **Step 4: Verify**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
test -f frontend/docs/adr/0008-consistency-loop-agent-pipeline.md && echo "ADR OK"
grep -q 'consistency-loop' frontend/CLAUDE.md && echo "pointer OK"
```
Expected: `ADR OK` and `pointer OK`.

- [ ] **Step 5: Commit**

```bash
git add frontend/docs/adr/0008-consistency-loop-agent-pipeline.md frontend/CLAUDE.md
git commit -m "docs(frontend): ADR 0008 + CLAUDE.md pointer for the consistency loop"
```

---

### Task 5: Manual proof run (INLINE — do not delegate)

**Files:**
- Modify: whichever `.vue`/`.ts` the loop fixes (unknown until the drift target is chosen).
- Produces: one merged PR — the proof the pipeline works end to end.

**Interfaces:**
- Consumes: the `/consistency-loop` skill (Tasks 1–3).

> Run this task inline in the orchestrating session. `/consistency-loop` dispatches its own
> subagents; nesting it inside an SDD subagent would double-nest dispatch. If executing via SDD,
> pause delegation and run Task 5 in the controller session.

- [ ] **Step 1: Find one real drift the gate can't catch**

The Phase 1 gate already blocks all objective drift, so hunt for a *subjective* inconsistency.
Scan for likely candidates:

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce/frontend
# status text that may be a plain label instead of <BStamp>:
grep -rniE 'paid|processing|canceled|cancelled|sold out|pending' src/pages src/components/domain --include=*.vue | grep -viE 'BStamp|stamp' | head
# sentimental copy the voice bans:
grep -rniE "oops|whoops|sorry|something went wrong" src --include=*.vue --include=*.ts | head
# --stamp-red used on something CTA-like:
grep -rn 'stamp-red' src --include=*.vue | head
```
Pick ONE concrete, real violation. Record the file, what's wrong, and the rubric item it hits.
If nothing real surfaces, tell the user and stop — do not fabricate drift (that would be the
"seed synthetic drift" option they declined).

- [ ] **Step 2: Confirm the tree is clean and on a fresh branch**

```bash
git status --porcelain    # expect empty
git checkout -b consistency/proof-run
```

- [ ] **Step 3: Run the loop**

Invoke `/consistency-loop` with the chosen target as scope. Let the full pass run:
implementer edits → `pnpm check:consistency` green → fresh `Explore` reviewer returns findings →
approver decides. Observe that each role behaves per SKILL.md.

Expected: the implementer fixes the drift, the gate stays green, the reviewer confirms
(`NO FINDINGS` or advisory-only), and the approver opens a **ready** PR (not draft) with the
drift + fix + gate result in the body.

- [ ] **Step 4: Verify the acceptance criteria held**

Confirm, from the run:
- The reviewer was a fresh subagent (dispatched via Agent, not a fork) with no implementer context.
- A PR exists (`gh pr view --json url,isDraft,labels`) and is **not** auto-merged.
- The gate is green on the PR branch.

- [ ] **Step 5: Merge the proof PR**

Present the PR to the user for review. On their approval, merge it (this is the human-on-the-loop
step the whole design exists for):

```bash
gh pr merge --squash --delete-branch
```
Then return to `main`, pull, and report Phase 2 complete.

```bash
git checkout main && git pull --ff-only
```

---

## Self-Review

**Spec coverage:**
- Goal 1 (`/consistency-loop` skill, four-role mechanics) → Tasks 1, 3.
- Goal 2 (rubric from foundations) → Task 2.
- Goal 3 (prove manually on one real inconsistency, merge PR) → Task 5.
- Goal 4 (reuse gate + `/design-kit`) → Global Constraints; enforced in Task 3's SKILL.md.
- Artifact: `SKILL.md` → Task 3; `rubric.md` → Task 2; `needs-human` label → Task 1; merged proof PR → Task 5; ADR + CLAUDE.md pointer → Task 4.
- Termination (cap 3 + `needs-human` draft) → Task 3 SKILL.md + Task 1 label.
- Non-goals (no triggers/`/goal`/visual-regression/auto-merge) → honored; no task adds them; "never auto-merge" enforced in Task 3 & 5.
- Success criterion "reviewer has no implementer access (fresh, not fork)" → Task 3 dispatch rule + Task 5 Step 4 verification.

**Placeholder scan:** The only intentionally-late-bound item is Task 5's drift target — unavoidable, since the spec's "one real inconsistency" must be discovered against the live tree; Task 5 Step 1 gives exact discovery commands, not a vague "find something." Task 4 Step 2 describes ADR section content rather than pasting a full ADR because it must follow the repo's own `0000-template.md` (read in Step 1) — the content to capture is enumerated explicitly.

**Type/name consistency:** Skill name `consistency-loop`, rubric path `.claude/skills/consistency-loop/rubric.md`, gate `pnpm check:consistency`, label `needs-human`, reviewer subagent type `Explore` (read-only), implementer subagent type `general-purpose` — used identically across Tasks 1–5.
