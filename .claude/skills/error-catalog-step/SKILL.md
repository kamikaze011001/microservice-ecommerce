---
name: error-catalog-step
description: >
  Use to run ONE iteration of the backend error-catalog sweep, then self-pace via /loop.
  Picks the next service lacking a messages/<svc>.properties bundle, gives its throw-sites
  stable dotted codes with %param% messages, wires core-exception-api if missing, verifies
  (mvn + check-error-catalog.sh), and commits. Ends at one human-merged PR.
  Trigger phrases: "/error-catalog-step", "/loop /error-catalog-step".
---

# error-catalog-step — one iteration of the backend error-catalog loop

**Announce at start:** "Running one error-catalog-step iteration."

Runs as `/loop /error-catalog-step` (no interval → self-paced). Durable state lives in git and
the message bundles — a killed session resumes from there. The only in-session state is a
transient blocked-service counter (Gate 2). Migrate EXACTLY ONE service per invocation, commit,
then stop or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — `node scripts/next-error-target.mjs` prints `DONE`. If the branch has
   commits, open the PR (below) and STOP. Else report "every service is coded" and STOP.
2. **Blocked stop** — track a blocked-service counter across this run; if 2 services in a row
   cannot be brought green (build/gate stays red), open the escape-hatch draft PR and STOP.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 6, open the PR and STOP.
4. **User interrupt** — the last commit is safe; re-running resumes from git state.

## The iteration
1. Ensure on branch `chore/error-catalog-sweep` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 6, open the Gate 1 PR and STOP.
3. Run `node scripts/next-error-target.mjs`. `DONE` → Gate 1. Else output is `<service-name>`.
4. For that service (mirror the product-service reference in the spec):
   - Add the `core-exception-api` dependency + `@EnableCoreExceptionApi` if absent.
   - Grep `throw new .*Exception` under `src/main`. Give each a `<domain>.<entity>.<reason>`
     code and params (the real IDs) via the `Xxx(code, params)` constructors. Fix any code that
     is an English sentence or FQN.
   - Create `src/main/resources/messages/<domain>.properties` with `%param%` messages.
   - Add both basenames to `application.i18n.resources` in `application.yml`.
5. **Verify (gate):** `make build` then `mvn -pl <service> -am -q verify` AND
   `./scripts/check-error-catalog.sh`. Green → `git add -A && git commit` (Co-Authored-By
   trailer). Red and unfixable → `git checkout -- .` and count a blocked service (Gate 2).
6. Report and let /loop schedule the next wake-up.

## Gate 1 PR
git push -u origin HEAD; gh pr create --base main --title "chore(backend): error-catalog sweep"
--body "Coded error catalog for: <list>. Each throw-site has a dotted code + %param% message.
check-error-catalog green."

## Gate 2 escape hatch
git commit --allow-empty -m "wip: error-catalog-step blocked — needs human"; push;
gh pr create --draft --base main --title "wip: error-catalog-step needs human"
--body "<blocked services + the specific blocker>"; gh pr edit --add-label needs-human

## Hard rules
- ONE service per invocation. Never batch.
- Never change `BaseResponse`. Codes are dotted, defined in a bundle before commit.
- Never auto-merge. Output is always a PR a human merges.
