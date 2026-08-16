# Eureka Check Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make the Eureka freshness check ask a question it can answer correctly, and make the test suite exercise the code that ships.

**Architecture:** two independent changes to `scripts/lib/eureka.sh` and its one caller. Task 1 collapses the duplicated formula into a single function that returns the verdict *and* the values, so `start.sh` needs one Eureka round-trip and the mutation test lands on the shipped path. Task 2 then changes that one comparison from equality-against-one-interface to membership-in-the-host's-addresses. **Unification comes first on purpose:** with the formula living in two places there is no single site at which to change the semantics.

**Tech Stack:** bash (the repo's `scripts/lib/*.sh` convention), `ifconfig`/`route`/`ipconfig` (macOS), `python3` for JSON parsing, `curl`.

**Design spec:** `docs/superpowers/specs/2026-08-16-eureka-check-hardening-design.md`.

## Global Constraints

- **Never `git push`.** A pre-push hook owns pushing; it is the human's job.
- **NOTHING THAT COSTS MONEY.** No `aws-*` target, no `terraform`, never `scripts/aws/up-all.sh`.
- **`rm` and `git rm` are sandbox-blocked** as assistant commands. Neither task needs them.
- **Never open or print `deploy/.env`** — real credentials.
- **Do NOT run `make down`, `make nuke`, or `make svc-stop`.** The human's compose stack is up and serving; `make up` is safe and idempotent.
- Do not touch the minikube cluster.
- Environment: macOS, GNU Make **3.81**, no `/usr/bin/timeout`, use `/bin/ls`. `python3`, `jq`, `lsof` present.
- **`rtk` both truncates AND substitutes command output** — plain `curl` once returned a 770-byte schema-stub instead of a real Eureka response. Use `rtk proxy <cmd>` for anything whose real output you depend on.
- **Assert non-empty before concluding "clean".** Eleven "empty result masquerading as a negative result" defects have landed in this repo, several inside guards written to prevent them.
- Test scripts print `N passed, M failed` and exit non-zero on failure.
- Every task ends with a commit, after running the tests it names.

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/lib/eureka.sh` | resolve the host's addresses and Eureka's registered address; decide staleness. Pure query + comparison, never restarts anything. |
| `scripts/lib/tests/eureka-test.sh` | the decision table, fixture-driven, runs with the stack down |
| `scripts/services/start.sh` | consumes the verdict inside its existing skip branch |
| `deploy/README.md` | one sentence naming the function |

---

## Task 1: One function for the verdict and the values

**Files:**
- Modify: `scripts/lib/eureka.sh` (add `eureka_staleness`, remove `registration_is_stale`)
- Modify: `scripts/services/start.sh:126-143`
- Modify: `scripts/lib/tests/eureka-test.sh`
- Modify: `deploy/README.md` (the sentence naming `registration_is_stale`)

**Interfaces:**
- Consumes existing, unchanged in this task: `current_host_ip()` (prints the default-route IP; exit 1 and prints nothing if undeterminable) and `eureka_registered_ip <port>`.
- Produces:
  ```
  eureka_staleness <http_port>
    stdout : "<reg_ip> <host_ip>"    (only on exit 0)
    exit 0 : STALE — caller should restart
    exit 1 : not stale, OR unknown (prints nothing)
  ```
  Task 2 changes what the second field contains; the contract shape does not change.

**Why this is first:** `registration_is_stale` is called **only by the test**. `start_one()`
re-implements the same formula inline — deliberately, because it needs both IPs for its log
line and calling the function then re-fetching them would double the Eureka round-trip. The
cost is that **a green suite says nothing about the shipped path**: the mutation test that
"proved the suite can fail" perturbed a function production never runs.

It is also why the semantic change in Task 2 cannot come first — with two copies of the
formula there is no single place to change.

- [ ] **Step 1: Write the failing test**

In `scripts/lib/tests/eureka-test.sh`, replace every `registration_is_stale` call with
`eureka_staleness` (five of them, cases 1-5), and add this case after the fixture check:

```bash
# 7. STALE prints "<reg_ip> <host_ip>" so the caller can log the values that
# drove the decision without a second Eureka round-trip. This is what lets one
# function serve both start.sh and this suite — the duplication it replaces
# meant a green run here proved nothing about the shipped path.
_out=$(HOST_IP_OVERRIDE=10.0.0.7 eureka_staleness 6868) && _rc=0 || _rc=1
if [ "$_rc" -eq 0 ] && [ "${_out%% *}" = "192.168.0.103" ] && [ "${_out#* }" = "10.0.0.7" ]; then
    ok "stale verdict carries reg_ip and host_ip on stdout"
else
    bad "expected '192.168.0.103 10.0.0.7', got '$_out' (rc=$_rc)"
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: FAIL — `eureka_staleness: command not found` on every rewritten case, exit non-zero.

- [ ] **Step 3: Add `eureka_staleness`, remove `registration_is_stale`**

In `scripts/lib/eureka.sh`, replace `registration_is_stale` (and its comment block) entirely
with:

```bash
# eureka_staleness <http_port>
#   exit 0 = STALE; stdout is "<reg_ip> <host_ip>" so the caller can log the
#            exact values the decision used
#   exit 1 = not stale, OR unknown — prints NOTHING
#
# Missing information NEVER yields 0. An unreachable Eureka, an unregistered
# service and an undeterminable host IP all mean "not stale", so the failure
# mode is "do nothing", never "restart everything".
#
# ONE function, not two: start.sh used to re-implement this formula inline to
# get the values for its log without a second round-trip, which left the test
# suite exercising a function production never called. Returning the values
# WITH the verdict removes the reason to duplicate it.
eureka_staleness() {
    local port=$1 host_ip reg_ip
    host_ip=$(current_host_ip) || return 1
    [ -n "$host_ip" ] || return 1
    reg_ip=$(eureka_registered_ip "$port") || return 1
    [ -n "$reg_ip" ] || return 1
    [ "$reg_ip" != "$host_ip" ] || return 1
    printf '%s %s\n' "$reg_ip" "$host_ip"
}
```

- [ ] **Step 4: Run the suite**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: `7 passed, 0 failed`, exit 0.

- [ ] **Step 5: Rewire `start.sh` to the single call**

In `scripts/services/start.sh`, replace lines 126-143 — from the comment beginning
`# Staleness uses the SAME fail-safe formula` through the `log_warn` line — with:

```bash
        # Staleness lives in ONE place: eureka_staleness() in eureka.sh returns
        # the verdict AND the values on stdout, so this needs a single Eureka
        # round-trip and the test suite exercises exactly the code that runs
        # here. (It used to be re-implemented inline for the log values, which
        # left the suite testing a function nothing in production called.)
        # Missing port, undeterminable host IP, or a failed lookup all mean
        # "not stale" — never "restart everything".
        local _pid _line _port _stale="" _reg="" _host=""
        _pid=$(cat "$PID_DIR/$name.pid")
        _line=$(svc_get "$name" 2>/dev/null) || _line=""
        _port=$([ -n "$_line" ] && svc_field "$_line" 2 || echo "")
        if [ -n "$_port" ]; then
            _stale=$(eureka_staleness "$_port") || _stale=""
        fi
        if [ -n "$_stale" ]; then
            _reg=${_stale%% *}
            _host=${_stale#* }
            log_warn "$name: Eureka registration is stale (registered $_reg, host is $_host) — restarting"
```

Leave everything from the next comment (`# spring-boot-maven-plugin forks…`) onward
untouched — the kill logic is not part of this change.

- [ ] **Step 6: Update the doc sentence**

`deploy/README.md` names `registration_is_stale()`. Change the name to `eureka_staleness()`.
Verify the surrounding sentence is still true — it described the algorithm, which has not
changed in this task.

- [ ] **Step 7: Verify nothing still references the removed function**

```bash
git grep -n 'registration_is_stale' -- . ':!docs/superpowers/'
```

Expected: **no hits.** `docs/superpowers/` is excluded because the spec and plan legitimately
name the old function. **Confirm the pattern works first** by grepping for `eureka_staleness`
and seeing hits — a typo'd pattern returns the same empty result as success.

- [ ] **Step 8: Verify live — the fast path must stay fast**

```bash
make up 2>&1 | tee /tmp/t1-nodrift.log
grep -c 'already running' /tmp/t1-nodrift.log
grep -c 'registration is stale' /tmp/t1-nodrift.log
```

Expected: `already running` **non-zero** (assert this first — a zero count means nothing was
running and the run proved nothing), and `registration is stale` **0**.

- [ ] **Step 9: Verify live — the stale path still fires**

```bash
HOST_IP_OVERRIDE=10.0.0.7 make up 2>&1 | tee /tmp/t1-drift.log
grep 'registration is stale' /tmp/t1-drift.log
```

Expected: one line per registered service (7: authorization-server, bff-service, gateway,
inventory-service, order-service, payment-service, product-service), each reading
`registered 192.168.0.103, host is 10.0.0.7`. The four unregistered services
(`eureka-server`, `orchestrator-service`, `mock-paypal-service`, `frontend`) must NOT appear.

Then confirm recovery: 11 services alive, and

```bash
curl -s 'http://localhost:6868/product-service/v1/products?page=1&size=1'
```

returns `"total":30`. **The response shape is `data.data` with `data.total` — not
`data.products`.**

- [ ] **Step 10: Prove the mutation test now lands on the shipped path**

Change `eureka_staleness`'s comparison line `[ "$reg_ip" != "$host_ip" ] || return 1` to
`[ "$reg_ip" = "$host_ip" ] || return 1` (inverted), re-run the suite, confirm it fails,
restore exactly, re-run to `7 passed, 0 failed`, and confirm `git diff scripts/lib/eureka.sh`
shows only this task's intended changes.

This is the property the task exists to restore: the function the suite perturbs is now the
function `start.sh` calls.

- [ ] **Step 11: Commit**

```bash
git add scripts/lib/eureka.sh scripts/lib/tests/eureka-test.sh scripts/services/start.sh deploy/README.md
git commit -m "fix(services): one staleness function, returning verdict and values

registration_is_stale() was called only by the test; start_one() re-implemented
the formula inline to get both IPs for its log without a second Eureka
round-trip. So a green suite said nothing about the shipped path — the mutation
test that proved it could fail perturbed a function production never ran.

eureka_staleness() returns the verdict AND the values on stdout, which removes
the reason to duplicate it."
```

---

## Task 2: Membership, not equality

**Files:**
- Modify: `scripts/lib/eureka.sh` (replace `current_host_ip` with `local_host_ipv4s`; change `eureka_staleness`'s comparison)
- Modify: `scripts/services/start.sh` (one log-message word)
- Modify: `scripts/lib/tests/eureka-test.sh`

**Interfaces:**
- Consumes from Task 1: `eureka_staleness <http_port>` — exit 0 = stale, stdout
  `"<reg_ip> <host_ip>"`. This task changes the second field to the full local set; the
  contract shape is unchanged.
- Produces: `local_host_ipv4s()` → prints every non-loopback local IPv4, **one per line**;
  exits 1 and prints nothing when none can be determined. Honours `HOST_IP_OVERRIDE` (meaning
  "pretend the host owns exactly these addresses" — space- or newline-separated, so the
  existing single-value cases keep working) and `FORCE_NO_HOST_IP` ("cannot determine").
  **`current_host_ip` is removed** — after Task 1 nothing outside this file calls it.

**Why:** the check compares Eureka's `ipAddr` against the **default-route** IP, while Spring
registers whatever `InetUtils` picks (first non-loopback site-local by enumeration order).
This host has five non-loopback site-local addresses — `192.168.0.103` (en1) plus four
docker/minikube bridges. They agree today. If they ever disagree the check returns a
**non-empty wrong** answer; every fail-safe here guards only against *empty*, so every service
is declared stale on every `make up`, permanently, because the replacement re-registers the
same address.

- [ ] **Step 1: Write the failing test**

In `scripts/lib/tests/eureka-test.sh`, insert after case 2 (the "matching IP" case):

```bash
# 2b. registered IP is a local address that is NOT the default-route one ->
# not stale. This is the case that loops forever under equality: Spring picks
# its address by InetUtils enumeration order, we picked ours from the default
# route, and a disagreement is a WRONG answer rather than an empty one — so no
# fail-safe catches it and every service restarts on every `make up`, forever.
HOST_IP_OVERRIDE=$'10.9.9.9\n192.168.0.103' eureka_staleness 6868 >/dev/null \
  && bad "a local (non-default-route) address must not be stale" \
  || ok "registered IP present in the local set is not stale"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: `7 passed, 1 failed`, exit 1, with the new case reporting
`FAIL a local (non-default-route) address must not be stale`.

The failure is deterministic. `current_host_ip` does `printf '%s' "$HOST_IP_OVERRIDE"`, which
returns the whole two-line value as a single string; the equality test compares
`192.168.0.103` against `10.9.9.9\n192.168.0.103`, they differ, and today's code says STALE.
That is exactly the bug: an address the host owns, reported as drift.

- [ ] **Step 3: Replace `current_host_ip` with `local_host_ipv4s`**

In `scripts/lib/eureka.sh`, replace the whole `current_host_ip` function with:

```bash
# local_host_ipv4s — every non-loopback IPv4 this host owns, one per line.
# Prints them; exits 1 and prints NOTHING if none can be determined.
#
# WHY A SET, NOT ONE ADDRESS: Spring registers whatever InetUtils picks — the
# first non-loopback site-local address by interface enumeration order. Any
# single address we compute is a GUESS at that choice. This host has five
# non-loopback site-locals (en1 plus four docker/minikube bridges), and the
# old default-route guess agreed with Spring only by luck. A disagreement
# produced a non-empty WRONG answer, which no fail-safe here catches — every
# service stale on every `make up`, permanently, because the replacement
# re-registers the same address.
#
# Asking "is Eureka's address one this host owns?" needs no guess at all.
local_host_ipv4s() {
    [ -n "${FORCE_NO_HOST_IP:-}" ] && return 1          # test seam: cannot determine
    if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
        # test seam: pretend the host owns exactly these addresses. Deliberately
        # UNQUOTED so a space- or newline-separated list splits into one per
        # line; existing single-value callers are unaffected. IPs contain no
        # glob characters, so word-splitting is safe here.
        # shellcheck disable=SC2086
        printf '%s\n' $HOST_IP_OVERRIDE
        return 0
    fi
    local ips
    ips=$(ifconfig -a 2>/dev/null | awk '/^[[:space:]]*inet /{print $2}' \
          | grep -v '^127\.' | sort -u)
    [ -n "$ips" ] || return 1
    printf '%s\n' "$ips"
}
```

- [ ] **Step 4: Switch `eureka_staleness` to membership**

Replace its body with:

```bash
eureka_staleness() {
    local port=$1 reg_ip locals
    locals=$(local_host_ipv4s) || return 1
    [ -n "$locals" ] || return 1
    reg_ip=$(eureka_registered_ip "$port") || return 1
    [ -n "$reg_ip" ] || return 1
    # Stale = Eureka's address is NOT one this host owns. `grep -qxF` is an
    # exact whole-line fixed-string match: -F so dots are literal, -x so
    # 192.168.0.10 never matches 192.168.0.103.
    printf '%s\n' "$locals" | grep -qxF "$reg_ip" && return 1
    printf '%s %s\n' "$reg_ip" "$(printf '%s' "$locals" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}
```

Update its comment block so the stdout contract reads `"<reg_ip> <local_ip…>"` and the
rationale says membership, not difference.

- [ ] **Step 5: Update the log wording in `start.sh`**

The second field is now a set, so `host is $_host` reads wrong. In
`scripts/services/start.sh`, change the `log_warn` line to:

```bash
            log_warn "$name: Eureka registration is stale (registered $_reg, this host has: $_host) — restarting"
```

Rename the variable `_host` to `_locals` in the three places it appears (the `local`
declaration, the assignment, and this line) so the name matches what it holds.

- [ ] **Step 6: Run the suite**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: `8 passed, 0 failed`, exit 0.

Case 7 still expects `"192.168.0.103 10.0.0.7"` — with `HOST_IP_OVERRIDE=10.0.0.7` the local
set is exactly one address, so the second field is unchanged. If that case fails, the set
joining is wrong, not the test.

- [ ] **Step 7: Prove the membership row can fail**

Temporarily change `printf '%s\n' "$locals" | grep -qxF "$reg_ip" && return 1` to
`false && return 1`, re-run, confirm failures appear and the suite exits non-zero, then
restore the line exactly and re-run to `8 passed, 0 failed`. Verify with
`git diff scripts/lib/eureka.sh` that only this task's intended changes remain.

- [ ] **Step 8: Verify against the live host**

```bash
source scripts/lib/eureka.sh
local_host_ipv4s
```

Expected: several addresses including `192.168.0.103`, none starting `127.`. **Assert the
output is non-empty** — an empty set makes every later check vacuously "not stale".

Then confirm the real registration reads as fresh:

```bash
source scripts/lib/eureka.sh
if eureka_staleness 6868 >/dev/null; then echo "STALE (unexpected)"; else echo "not stale (expected)"; fi
```

- [ ] **Step 9: Verify live end to end**

```bash
make up 2>&1 | tee /tmp/t2-nodrift.log
grep -c 'already running' /tmp/t2-nodrift.log
grep -c 'registration is stale' /tmp/t2-nodrift.log
```

Expected: `already running` **non-zero**, `registration is stale` **0**.

Then the drift path:

```bash
HOST_IP_OVERRIDE=10.0.0.7 make up 2>&1 | tee /tmp/t2-drift.log
grep 'registration is stale' /tmp/t2-drift.log
```

Expected: 7 lines, each reading `registered 192.168.0.103, this host has: 10.0.0.7`. Confirm
recovery: 11 services alive and the catalog returns `"total":30`.

- [ ] **Step 10: Commit**

```bash
git add scripts/lib/eureka.sh scripts/lib/tests/eureka-test.sh scripts/services/start.sh
git commit -m "fix(services): staleness is membership, not equality to one interface

The check compared Eureka's ipAddr against the DEFAULT-ROUTE address while
Spring registers whatever InetUtils picks (first non-loopback site-local by
enumeration order). This host has five such addresses; they agreed by luck.

A disagreement is a non-empty WRONG answer, and every fail-safe here guards
only against empty — so it would declare every service stale on every make up,
permanently, since the replacement re-registers the same address.

Stale now means: the registered address is not one this host owns. The log
names every address the host has, which also explains why the check fired."
```

---

## Verification summary

| Gate | Where | Criterion |
|---|---|---|
| membership row | offline suite | a local non-default-route address reads not-stale |
| both fail-safes | offline suite | unreachable Eureka and undeterminable set → explicit not-stale verdicts |
| values on stdout | offline suite | stale prints `<reg_ip> <local…>` |
| mutation lands on shipped code | offline suite | perturbing `eureka_staleness` fails the suite |
| fast path unchanged | live compose | `already running` non-zero, `registration is stale` **0** |
| stale path | live compose | exactly the 7 registered services restart; catalog then serves `total: 30` |
| no dangling reference | repo | `registration_is_stale` gone outside `docs/superpowers/` |
