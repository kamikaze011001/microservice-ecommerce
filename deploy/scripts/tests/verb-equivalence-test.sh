#!/usr/bin/env bash
# Layer A — offline equivalence for the Phase 6 unified verbs
# (`make <verb> ENV=<env>`, deploy/status/teardown/rebuild/bootstrap/
# image-build) against the OLD targets they wrap. See
# docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md §4 and
# .superpowers/sdd/2026-08-09-unified-make-verbs/task-4-brief.md.
#
#   ./deploy/scripts/tests/verb-equivalence-test.sh     (from any cwd)
#
# THREE THINGS THE BRIEF GOT WRONG, CORRECTED HERE (see task-4-report.md):
#
# 1. "Strip line 1 and diff the rest" does not work. GNU Make 3.81's `-n`
#    recursion into a sub-make is lexical on the RULE'S OWN unexpanded
#    recipe text — the verbs reach `$(MAKE)` through the `dispatch` macro
#    (Makefile, one level of indirection), so `make -n <verb> ENV=<env>`
#    prints exactly ONE line: the dispatch shell command, never the
#    recursed target's own recipe. Comparing that line's "rest" against a
#    baseline compares empty-ish text against real text for the wrong
#    reason. Instead: RESOLVE the mapping (parse `t="..."` out of that one
#    dispatch line — the same live mechanism the Makefile itself uses, not
#    a copy of the VERB_* table), THEN diff *that resolved target's own*
#    `make -n --no-print-directory <target>` against `baseline/<t>.txt`.
#
# 2. Scope is wider than the six verbs. `ENV ?= compose` (added, then
#    reverted, in Task 2) broke five pre-existing targets that read bare
#    $(ENV) with their own default: k9s, k8s-use (shell `case "$(ENV)" in
#    ""|local) ...`) and k8s-platform, k8s-infra-helm, k8s-apps-helm (make
#    `$(or $(ENV),local-k8s)`). None of the 14 Task-1 baselines cover them.
#    This suite asserts all five still resolve to their own default
#    (local / local-k8s) with no ENV= given — see Part 3.
#
# 3. The captured baselines contain one machine-specific absolute path:
#    the resolved $(MAKE) in k8s-bootstrap.txt line 55
#    (`/Library/Developer/CommandLineTools/usr/bin/make k8s-status` on
#    this host). Diffed literally, this suite would pass here and fail on
#    any other host or in CI. `norm()` below rewrites `<anything>/make ` to
#    `MAKE ` on both sides before every diff.
#
# Safety: everything here is `make -n` (never executes a recipe) EXCEPT
# one deliberate real invocation — `make image-build ENV=compose` — which
# is required because `-n` always exits 0 regardless of whether the
# dispatch macro's own `exit 1` guard would fire; there is no way to
# observe "fails to dispatch" without really running it. Before doing so,
# this script re-derives the resolved target from a fresh `-n` dispatch
# line and refuses to execute for real unless that target is still empty
# (i.e. still genuinely unmapped) — so a regression that points
# image-build/compose at a real target is reported as a FAIL, never
# silently executed. No kubectl/helm/aws/docker command ever runs; no
# cluster, credentials, or backend are required; nothing is printed that
# could contain a secret.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BASELINE_DIR="$HERE/baseline"

python3 - "$ROOT" "$BASELINE_DIR" <<'PY'
import re
import subprocess
import sys
import pathlib

ROOT, BASELINE_DIR = (pathlib.Path(a) for a in sys.argv[1:3])

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"

DISPATCH_RE = re.compile(r't="([^"]*)"')
CASE_BLOCK_RE = re.compile(r'(case ".*?esac;)', re.S)


def mk(args, dry=True):
    """Run make from ROOT, cwd-independent of wherever this script was
    invoked from. dry=True adds -n --no-print-directory (never executes a
    recipe); dry=False runs for real (only ever used for the one
    deliberate, pre-guarded case below)."""
    cmd = ["make"] + (["-n", "--no-print-directory"] if dry else ["--no-print-directory"]) + list(args)
    return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)


def norm(text):
    """Rewrite the machine-specific resolved $(MAKE) absolute path (e.g.
    /Library/Developer/CommandLineTools/usr/bin/make) to a stable token so
    this diff isn't only ever green on the machine that captured the
    baseline. See correction #3 above."""
    return re.sub(r'^\S+/make ', 'MAKE ', text, flags=re.M)


# Reviewer finding (Task 4 review): the CASE_BLOCK_RE extraction alone is
# NOT a safety boundary — it captures everything from `case "` through the
# first `esac;` textually, with no regard for what's inside. Today that
# happens to be safe only because k9s/k8s-use keep their real kubectl/k9s
# work textually AFTER `esac;`; a synthetic block like
# `""|local) ctx=microecom; kubectl config use-context danger ;;` placed
# BEFORE `esac;` would execute for real. CASE_BLOCK_VALIDATE_RE enforces
# the only shape this script is willing to execute: a `case "<value>" in`
# header, one or more `<pattern>) ctx=<ident> ;;` assignment arms and/or
# exactly one `*) echo "..."; exit <n> ;;` error arm, and a trailing
# `esac;` — nothing else. Anything that doesn't match this shape is
# REJECTED and resolve_ctx fails loudly (never silently skips the check
# and never executes unvalidated text).
CASE_HEADER_RE = re.compile(r'^case "[^"]*" in *\\?$')
# Bash performs command substitution on case PATTERNS, not just bodies, so a
# quoted pattern containing $(...) or `...` must be rejected the same way
# CASE_ARM_ERROR_RE already excludes backtick/dollar from its quoted string —
# that exclusion was missing here. Without it, e.g.
# `"$(touch /tmp/PWNED; echo x)"|"local") ctx=microecom ;;` matches (no bare
# `"` inside the quotes) and validate_case_block() would wave it through.
CASE_ARM_ASSIGN_RE = re.compile(
    r'^\s*(?:"[^"`$]*"|\*|[A-Za-z0-9_]+)(?:\s*\|\s*(?:"[^"`$]*"|\*|[A-Za-z0-9_]+))*\)\s*'
    r'ctx=[A-Za-z0-9_-]+\s*;;\s*\\?$'
)
CASE_ARM_ERROR_RE = re.compile(
    r'^\s*\*\)\s*echo\s+"[^"`$]*"\s*;\s*exit\s+[0-9]+\s*;;\s*\\?$'
)
CASE_ESAC_RE = re.compile(r'^\s*esac;\s*$')


def validate_case_block(block):
    """Reject anything that isn't exactly `case "..." in` / assignment or
    error arms / `esac;` — see the comment above resolve_ctx. Returns
    (ok, reason_if_rejected)."""
    lines = block.splitlines()
    if len(lines) < 2:
        return False, "block has fewer than 2 lines (no header+esac shape)"
    if not CASE_HEADER_RE.match(lines[0]):
        return False, f"first line is not a bare `case \"...\" in` header: {lines[0]!r}"
    if not CASE_ESAC_RE.match(lines[-1]):
        return False, f"last line is not a bare `esac;`: {lines[-1]!r}"
    for line in lines[1:-1]:
        if not line.strip():
            continue
        if CASE_ARM_ASSIGN_RE.match(line) or CASE_ARM_ERROR_RE.match(line):
            continue
        return False, f"line does not match the allowed `ctx=` / error-arm shape: {line!r}"
    return True, None


def resolve_ctx(recipe_text):
    """k9s / k8s-use resolve their target context via a plain shell `case
    "$(ENV)" in ""|local) ctx=... ;; ...` — shell-time, not visible in -n
    text as a value. Execute ONLY that case/esac block (extracted from the
    live -n output, which already has $(ENV) substituted in) in a bash
    subshell to see what ctx it actually assigns, then stop — the
    subsequent kubectl/k9s invocation lines are never included by shape,
    and validate_case_block() rejects the block outright (no execution) if
    its content ever stops matching the narrow ctx-assignment shape this
    function is willing to run. Returns (ctx_or_None, error_or_None)."""
    m = CASE_BLOCK_RE.search(recipe_text)
    if not m:
        return None, 'no `case "..." ... esac;` block found in recipe text'
    block = m.group(1)
    ok, reason = validate_case_block(block)
    if not ok:
        return None, f"REFUSED to execute: block failed safety validation ({reason})"
    script = block + '\necho "__CTX__=$ctx"\n'
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    cm = re.search(r"__CTX__=(\S*)", r.stdout)
    if r.returncode != 0 or not cm or not cm.group(1):
        return None, (f"case block did not resolve ctx (rc={r.returncode}, "
                       f"stdout={r.stdout.strip()!r}, stderr={r.stderr.strip()!r})")
    return cm.group(1), None


results = []  # (section, name, "PASS"|"FAIL", detail)


def record(section, name, ok, detail=None):
    results.append((section, name, "PASS" if ok else "FAIL", detail))


# ---------------------------------------------------------------------
# Part 1 — verb x env -> old-target dispatch mapping (resolve-then-diff).
# 14 pairs = the same 14 old targets Task 1 baselined (9 from the four
# Task-2 verbs + 3 bootstrap + 2 image-build). The right-hand baseline
# filename doesn't always match the resolved target name: `status` and
# `bootstrap` collided with pre-existing compose target names, so their
# original recipes were moved verbatim to `status-compose` /
# `bootstrap-compose` (Tasks 2-3) while the baseline files kept the OLD
# target's name (status.txt / bootstrap.txt).
# ---------------------------------------------------------------------
PAIRS = [
    ("deploy",       "compose", "svc-start.txt"),
    ("deploy",       "k8s",     "k8s-apps.txt"),
    ("status",       "compose", "status.txt"),
    ("status",       "k8s",     "k8s-status.txt"),
    ("teardown",     "compose", "down.txt"),
    ("teardown",     "k8s",     "k8s-down.txt"),
    ("teardown",     "aws",     "aws-down.txt"),
    ("rebuild",      "compose", "svc-restart.txt"),
    ("rebuild",      "k8s",     "k8s-rebuild.txt"),
    ("bootstrap",    "compose", "bootstrap.txt"),
    ("bootstrap",    "k8s",     "k8s-bootstrap.txt"),
    ("bootstrap",    "aws",     "aws-all.txt"),
    ("image-build",  "k8s",     "k8s-build.txt"),
    ("image-build",  "aws",     "aws-push.txt"),
]

for verb, env, baseline_name in PAIRS:
    name = f"{verb} ENV={env}"

    dispatch = mk([verb, f"ENV={env}"])
    disp_text = dispatch.stdout
    if not disp_text.strip():
        record("mapping", name, False,
               f"`make -n {verb} ENV={env}` produced NOTHING (dispatch line itself empty)")
        continue

    m = DISPATCH_RE.search(disp_text)
    if not m or not m.group(1):
        record("mapping", name, False,
               f"could not resolve t=\"...\" from dispatch output: {disp_text.strip()!r}")
        continue
    target = m.group(1)

    baseline_path = BASELINE_DIR / baseline_name
    baseline_text = baseline_path.read_text() if baseline_path.exists() else ""
    if not baseline_text.strip():
        record("mapping", name, False,
               f"baseline/{baseline_name} MISSING or EMPTY (right-hand side; resolved target={target!r})")
        continue

    # ENV=<env> is passed here too, not just to the dispatch call above: the
    # dispatch macro invokes the sub-make with ENV still set (it's inherited,
    # not stripped), so the proof's left-hand side must match what dispatch
    # actually runs. All 14 resolved targets are ENV-blind today so this is
    # not a live defect, but a bare `make -n <target>` would silently stop
    # catching a future target that starts reading $(ENV).
    live = mk([target, f"ENV={env}"])
    live_text = live.stdout
    if not live_text.strip():
        record("mapping", name, False,
               f"`make -n {target}` (resolved from {verb} ENV={env}) produced NOTHING (left-hand side)")
        continue

    a, b = norm(live_text), norm(baseline_text)
    if a != b:
        la, lb = a.splitlines(), b.splitlines()
        detail = (f"target={target!r} (resolved from {verb} ENV={env}) != baseline/{baseline_name} "
                   f"({len(la)} vs {len(lb)} lines)")
        for i, (x, y) in enumerate(zip(la, lb)):
            if x != y:
                detail += f"; first diff at line {i + 1}: live={x!r} baseline={y!r}"
                break
        else:
            detail += "; common prefix matches, one side has extra trailing lines"
        record("mapping", name, False, detail)
        continue

    record("mapping", name, True, f"-> {target}")


# ---------------------------------------------------------------------
# Part 2 — declared difference: image-build ENV=compose has no baseline
# and must FAIL TO DISPATCH (compose builds no container images). Assert
# non-zero exit + message names "compose". Fails loudly (never silently
# executes) if this ever starts resolving to a real target instead.
# ---------------------------------------------------------------------
name = "image-build ENV=compose (declared: must fail to dispatch)"
dispatch = mk(["image-build", "ENV=compose"])

if not dispatch.stdout.strip():
    # Same guard as Part 1: an empty dispatch line is NOT the same thing as
    # a confirmed-unmapped (t="") dispatch line -- it means something broke
    # upstream of the check this suite is trying to run. Never fall through
    # to the real invocation on a guess.
    record("declared", name, False,
           "`make -n image-build ENV=compose` produced NOTHING (dispatch line itself empty) — "
           "cannot tell mapped from unmapped, refusing to guess")
elif not DISPATCH_RE.search(dispatch.stdout):
    # Regex found no t="..." at all -- distinct from finding t="" (matched,
    # empty target). If the dispatch macro's textual shape ever changes,
    # this stops the suite from silently treating a real mapping as
    # unmapped and running the real invocation against it.
    record("declared", name, False,
           f"could not find t=\"...\" in dispatch output — dispatch macro's shape may have "
           f"changed: {dispatch.stdout.strip()!r} — refusing to treat this as unmapped")
else:
    resolved = DISPATCH_RE.search(dispatch.stdout).group(1)
    if resolved:
        record("declared", name, False,
               f"REGRESSION: now resolves to target={resolved!r} instead of being unmapped — "
               f"refusing to execute it for real; this must go back to failing to dispatch")
    else:
        real = mk(["image-build", "ENV=compose"], dry=False)
        ok = real.returncode != 0 and "compose" in real.stderr
        if ok:
            record("declared", name, True,
                   f"exit={real.returncode}, stderr names compose: {real.stderr.strip()!r}")
        else:
            record("declared", name, False,
                   f"expected non-zero exit + message naming compose; got "
                   f"exit={real.returncode} stdout={real.stdout.strip()!r} stderr={real.stderr.strip()!r}")


# ---------------------------------------------------------------------
# Part 3 — ENV-default resolution. Targets that read bare $(ENV) with
# their own default must still resolve that default with no ENV= given —
# this is exactly what the (now-reverted) global `ENV ?= compose` broke
# for all five of these in Task 2, and no Task-1 baseline covers them.
# ---------------------------------------------------------------------

# 3a. Make-time default via $(or $(ENV),local-k8s)) -- fully expanded by
# make itself before -n even prints, so no-ENV and ENV=local-k8s must be
# BYTE-IDENTICAL, no normalisation needed (no $(MAKE) in these recipes).
for target in ("k8s-platform", "k8s-infra-helm", "k8s-apps-helm"):
    name = f"{target} (no ENV) == ENV=local-k8s"
    d = mk([target])
    e = mk([target, "ENV=local-k8s"])
    if not d.stdout.strip():
        record("env-default", name, False, f"`make -n {target}` (no ENV) produced NOTHING")
        continue
    if not e.stdout.strip():
        record("env-default", name, False, f"`make -n {target} ENV=local-k8s` produced NOTHING")
        continue
    if d.stdout != e.stdout:
        record("env-default", name, False,
               "no-ENV output != ENV=local-k8s output (byte-diff) — default may have drifted")
        continue
    record("env-default", name, True, None)

# 3b. Shell-time default via `case "$(ENV)" in ""|local) ctx=microecom ;;
# ...` -- $(ENV) is only textually substituted by make (empty string vs.
# "local"), so the two -n captures are legitimately NOT byte-identical
# (different literal case-argument text). Execute just the case/esac
# block for real (see resolve_ctx) to see what ctx each actually resolves
# to, and require them equal.
for target in ("k9s", "k8s-use"):
    name = f"{target} (no ENV) resolves like ENV=local"
    d = mk([target])
    e = mk([target, "ENV=local"])
    if not d.stdout.strip():
        record("env-default", name, False, f"`make -n {target}` (no ENV) produced NOTHING")
        continue
    if not e.stdout.strip():
        record("env-default", name, False, f"`make -n {target} ENV=local` produced NOTHING")
        continue

    ctx_default, err_d = resolve_ctx(d.stdout)
    ctx_explicit, err_e = resolve_ctx(e.stdout)
    if ctx_default is None:
        record("env-default", name, False, f"no-ENV side: {err_d}")
        continue
    if ctx_explicit is None:
        record("env-default", name, False, f"ENV=local side: {err_e}")
        continue
    if ctx_default != ctx_explicit:
        record("env-default", name, False,
               f"no-ENV resolved ctx={ctx_default!r}, ENV=local resolved ctx={ctx_explicit!r} — "
               f"default has drifted away from ENV=local")
        continue
    record("env-default", name, True, f"both resolve ctx={ctx_default!r}")


# ---------------------------------------------------------------------
# Total-count assertion — cheap insurance against the recurring
# "empty result masquerading as a negative result" failure mode (seven
# instances across this project's phases, several inside guards written
# to prevent exactly that). 0 passed + 0 failed exits 0 today because
# nothing checks that `results` itself is non-empty/complete — a future
# refactor that silently emptied PAIRS or short-circuited a section would
# still print "0 passed, 0 failed -> PASS". 14 (Part 1) + 1 (Part 2) + 5
# (Part 3) = 20 is the fixed, known-good count for this suite's structure.
# ---------------------------------------------------------------------
EXPECTED_TOTAL = 20
if len(results) != EXPECTED_TOTAL:
    print(f"{RED}FATAL{RESET} expected {EXPECTED_TOTAL} checks to have recorded a result, got "
          f"{len(results)} — the check list was silently narrowed (a PAIRS entry dropped, a "
          f"section short-circuited, etc.); refusing to report a summary over an incomplete set")
    sys.exit(1)


# ---------------------------------------------------------------------
# Report — matches deploy/seed/tests/equivalence-test.sh house style:
# name which check failed and how, never a full blob dump.
# ---------------------------------------------------------------------
SECTION_TITLES = {
    "mapping": "Part 1: verb x env -> old-target dispatch (resolve-then-diff)",
    "declared": "Part 2: declared difference (image-build ENV=compose)",
    "env-default": "Part 3: ENV-default resolution (bare $(ENV) targets)",
}

for section in ("mapping", "declared", "env-default"):
    rows = [r for r in results if r[0] == section]
    if not rows:
        continue
    print(f"-- {SECTION_TITLES[section]} --")
    for _, name, status, detail in rows:
        if status == "PASS":
            suffix = f" ({detail})" if detail else ""
            print(f"{GREEN}ok{RESET}   {name}{suffix}")
        else:
            print(f"{RED}FAIL{RESET} {name}: {detail}")

passed = sum(1 for _, _, s, _ in results if s == "PASS")
failed = [r for r in results if r[2] == "FAIL"]

summary = f"{passed} passed, {len(failed)} failed"
status = f"{GREEN}PASS{RESET}" if not failed else f"{RED}FAIL{RESET}"
print(f"{summary}    -> {status}")

sys.exit(0 if not failed else 1)
PY
