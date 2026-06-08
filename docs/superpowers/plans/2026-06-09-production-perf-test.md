# Production-Shaped Performance Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-shaped k6 load test — a conversion-funnel traffic model runnable under three profiles (smoke / soak / stress) — alongside the existing pure-saga regression test, staying in-cluster on the kind setup.

**Architecture:** One self-contained `storefront-flow.js` (k6 ConfigMaps mount a single flat file, no imports) builds its `options.scenarios` and `options.thresholds` conditionally from `__ENV.PROFILE`. A single parameterized Job manifest (`storefront-job.yaml`) sets `PROFILE`; three Makefile targets rewrite the placeholder and fire the Job. The existing `payment-flow.js` / `k8s-payment-stress` stay untouched as the regression baseline.

**Tech Stack:** k6 0.54.0 (run as `grafana/k6:0.54.0` — there is **no local k6 binary**, so script validation uses `docker run … inspect`), Kubernetes (kind, namespaces `apps` + `monitoring` live), VictoriaMetrics remote-write → Grafana dashboard #19665, GNU Make.

**Spec:** `docs/superpowers/specs/2026-06-08-production-perf-test-design.md` (approved). Read it for the funnel rationale; this plan contains the complete code.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `k8s/apps/base/k6-stress/storefront-flow.js` | Self-contained funnel driver: env knobs, helpers, `buildScenarios()`, `buildThresholds()`, `setup()`, funnel `default()` | Create |
| `k8s/apps/base/k6-stress/storefront-job.yaml` | Parameterized k6 Job (PROFILE placeholder, VM remote-write, PRODUCT_IDS override) | Create |
| `Makefile` | `k8s-storefront-smoke/soak/stress` + shared `k8s-storefront-run` + `k8s-storefront-logs` + help/.PHONY | Modify |
| `docs/load-test-model-and-capacity.md` | Document the funnel model + three profiles | Modify (append section) |
| `docs/performance-test-guide.md` | How to run each profile + where to read soak stability | Modify (append section) |

**Unchanged / reused:** `payment-flow.js`, `payment-job.yaml`, `k8s-payment-stress*`, `make k8s-seed-perftest`, the VictoriaMetrics wiring.

**Standing constraints (carry through every commit):** stage only the paths listed in each Step 5 — **never** `git add -A` / `git add .`; **never** stage `.claude/settings.json`; commit messages end with the `Co-Authored-By` trailer shown in each commit step.

---

## Task 1: storefront-flow.js — the funnel driver

**Files:**
- Create: `k8s/apps/base/k6-stress/storefront-flow.js`

k6 has no unit-test framework (it *is* the test). The "test" here is `k6 inspect`, which parses the script and prints the resolved `options` JSON — proving the script is syntactically valid AND that `PROFILE` selects the right executor. We have no local k6, so we run it via Docker.

- [ ] **Step 1: Write the failing test (inspect before the file exists)**

Run:
```bash
docker run --rm -e PROFILE=smoke \
  -v "$PWD/k8s/apps/base/k6-stress:/scripts" \
  grafana/k6:0.54.0 inspect /scripts/storefront-flow.js
```
Expected: FAIL — `The moduleSpecifier "/scripts/storefront-flow.js" couldn't be found` (file does not exist yet).

- [ ] **Step 2: Write the complete script**

Create `k8s/apps/base/k6-stress/storefront-flow.js` with exactly this content:

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

// Self-contained in-cluster PRODUCTION-SHAPED storefront load driver.
// Models a conversion funnel (browse -> detail -> login -> cart -> order ->
// pay) where most sessions only browse and a checkout-heavy minority pay.
// One script, three profiles selected by PROFILE: smoke | soak | stress.
// No external imports (k6 ConfigMaps mount a single flat file), so everything
// is inlined here — mirrors payment-flow.js, which stays as the pure-saga
// regression baseline.
//
// Reachability — why no hostAliases: the mock embeds the browser-facing
// ingress host (api.microecom.local) in the approve link; an in-cluster pod
// can't resolve it. We rewrite that origin back to the gateway Service DNS at
// every redirect hop (toCluster), same as payment-flow.js.
//
// Prerequisites: perftest users (make k8s-seed-perftest) and the PRODUCT_IDS
// must exist; setup() fails loudly otherwise.

const BASE = __ENV.BASE_URL || 'http://gateway.apps.svc.cluster.local:6868';
const INGRESS_ORIGIN = __ENV.INGRESS_ORIGIN || 'http://api.microecom.local';
const PROFILE = __ENV.PROFILE || 'smoke';

const ADMIN_USER = __ENV.ADMIN_USER || 'perftest_admin';
const ADMIN_PASS = __ENV.ADMIN_PASS || 'Admin@123456';
const USER_PASS = __ENV.USER_PASS || 'Test@123456';
const USER_COUNT = parseInt(__ENV.USER_COUNT || '100', 10);
const PRODUCT_IDS = (__ENV.PRODUCT_IDS || 'test-product-1,test-product-2,test-product-3')
  .split(',').map((s) => s.trim());

// Profile knobs (all env-overridable; defaults match the design spec).
const SOAK_VUS = parseInt(__ENV.SOAK_VUS || '30', 10);
const SOAK_DURATION = __ENV.SOAK_DURATION || '30m';
const STRESS_START_RATE = parseInt(__ENV.STRESS_START_RATE || '10', 10);
const STRESS_PEAK_RATE = parseInt(__ENV.STRESS_PEAK_RATE || '120', 10);
const STRESS_DURATION = __ENV.STRESS_DURATION || '15m';
const STRESS_MAX_VUS = parseInt(__ENV.STRESS_MAX_VUS || '150', 10);

// In the open-model stress profile, real think-times would pin VUs and cap the
// achievable arrival rate at maxVUs instead of loading the SUT. Compress them.
const THINK_SCALE = PROFILE === 'stress' ? 0.1 : 1.0;

// ---- profile -> scenario ---------------------------------------------------
function buildScenarios(profile) {
  if (profile === 'soak') {
    return {
      soak: {
        executor: 'constant-vus',
        vus: SOAK_VUS,
        duration: SOAK_DURATION,
        gracefulStop: '30s',
      },
    };
  }
  if (profile === 'stress') {
    return {
      stress: {
        executor: 'ramping-arrival-rate',
        startRate: STRESS_START_RATE,
        timeUnit: '1s',
        preAllocatedVUs: 50,
        maxVUs: STRESS_MAX_VUS,
        stages: [
          { target: STRESS_PEAK_RATE, duration: STRESS_DURATION },
        ],
        gracefulStop: '30s',
      },
    };
  }
  // smoke (default) — parity with payment-flow.js
  return {
    smoke: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 50 },
        { duration: '3m', target: 50 },
        { duration: '30s', target: 0 },
      ],
      gracefulStop: '30s',
    },
  };
}

// ---- profile -> thresholds -------------------------------------------------
function buildThresholds(profile) {
  if (profile === 'soak') {
    // Strict — this is the regression/drift catcher. login p95 relaxed to
    // 1500ms: the bcrypt ceiling is a documented known item, not what a soak
    // measures. Latency STABILITY over time is judged on Grafana #19665.
    return {
      http_req_failed: ['rate<0.01'],
      checks: ['rate>0.99'],
      'http_req_duration{name:browse}': ['p(95)<500'],
      'http_req_duration{name:detail}': ['p(95)<500'],
      'http_req_duration{name:create_payment}': ['p(95)<2000'],
      'http_req_duration{name:login}': ['p(95)<1500'],
    };
  }
  if (profile === 'stress') {
    // Non-aborting: we WANT the ramp to complete and expose the ceiling.
    // Report the rate/concurrency at which http_req_failed first crosses 5%.
    return {
      http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: false }],
      checks: [{ threshold: 'rate>0.95', abortOnFail: false }],
      'http_req_duration{name:create_payment}': [{ threshold: 'p(95)<2000', abortOnFail: false }],
      'http_req_duration{name:login}': [{ threshold: 'p(95)<1500', abortOnFail: false }],
    };
  }
  // smoke — unchanged SLO from payment-flow.js
  return {
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
    'http_req_duration{name:create_payment}': ['p(95)<2000'],
    'http_req_duration{name:login}': ['p(95)<800'],
  };
}

export const options = {
  scenarios: buildScenarios(PROFILE),
  thresholds: buildThresholds(PROFILE),
};

// ---- helpers ---------------------------------------------------------------
// Rewrite the browser-facing ingress origin to the in-cluster gateway.
function toCluster(url) {
  return url.replace(INGRESS_ORIGIN, BASE);
}

// Uniform random think-time in [min,max] seconds, compressed in stress.
function thinkTime(min, max) {
  sleep((min + Math.random() * (max - min)) * THINK_SCALE);
}

// Sequential funnel gate: true if the session continues past this gate.
function passed(continueProb) {
  return Math.random() < continueProb;
}

function pickProduct() {
  return PRODUCT_IDS[Math.floor(Math.random() * PRODUCT_IDS.length)];
}

// ---- setup -----------------------------------------------------------------
export function setup() {
  // Probe a routed PERMIT_ALL business endpoint (gateway does NOT route
  // /actuator/**). Storefront browse is PERMIT_ALL — confirms gateway+product.
  const health = http.get(`${BASE}/product-service/v1/products?page=1&size=1`);
  if (health.status !== 200) {
    throw new Error(`gateway/product-service not reachable: ${health.status} ${health.body}`);
  }

  // Admin login + top up inventory so orders can be placed. The oversell fix
  // made update()/PATCH sync both the DB stock column and the Redis available:
  // counter, so this correctly seeds the reservation authority.
  const adminRes = http.post(`${BASE}/authorization-server/v1/auth:login`,
    JSON.stringify({ username: ADMIN_USER, password: ADMIN_PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'admin_login' } });
  if (adminRes.status !== 200) {
    throw new Error(`admin login failed (${adminRes.status}); seed perftest users first: ${adminRes.body}`);
  }
  const adminToken = adminRes.json('data.access_token');
  for (const pid of PRODUCT_IDS) {
    const topUp = http.patch(`${BASE}/inventory-service/v1/inventories/${pid}`,
      JSON.stringify({ quantity: 1000000, is_add: true }),
      { headers: { 'Authorization': `Bearer ${adminToken}`, 'Content-Type': 'application/json' },
        tags: { name: 'setup_inventory' } });
    // Fail loudly: an unchecked top-up silently 403s when perftest_admin has no
    // ADMIN role, leaving the catalog to deplete mid-run and masquerade as a
    // latency/throughput failure. Stop here instead.
    if (topUp.status < 200 || topUp.status >= 300) {
      throw new Error(`inventory top-up failed for ${pid} (HTTP ${topUp.status}); ` +
        `perftest_admin likely missing the ADMIN role — re-run make k8s-seed-perftest: ${topUp.body}`);
    }
  }
  return {};
}

// ---- the funnel ------------------------------------------------------------
export default function () {
  // 1) Browse a catalog page (anonymous) — 100% of sessions.
  const page = 1 + Math.floor(Math.random() * 5);
  const browseRes = http.get(`${BASE}/product-service/v1/products?page=${page}&size=12`,
    { tags: { name: 'browse' } });
  check(browseRes, { 'browse 200': (r) => r.status === 200 });
  thinkTime(1, 4);

  // 2) View a product detail (anonymous) — 60% continue.
  if (!passed(0.60)) return;
  const pid = pickProduct();
  const detailRes = http.get(`${BASE}/product-service/v1/products/${pid}`,
    { tags: { name: 'detail' } });
  check(detailRes, { 'detail 200': (r) => r.status === 200 });
  thinkTime(2, 6);

  // 3) Login — conditional 0.667 (=> 40% cumulative). Only sessions that will
  //    add to cart pay the bcrypt cost, so anonymous browsing stays cheap.
  if (!passed(0.667)) return;
  const username = `perftest_user_${(__VU % USER_COUNT) + 1}`;
  const loginRes = http.post(`${BASE}/authorization-server/v1/auth:login`,
    JSON.stringify({ username, password: USER_PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } });
  if (!check(loginRes, { 'login 200': (r) => r.status === 200 })) return;
  const token = loginRes.json('data.access_token');
  const authHeaders = { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' };

  // 4) Add to cart (authenticated) — same 40% cohort as login.
  const cartRes = http.post(`${BASE}/order-service/v1/shopping-carts:add-item`,
    JSON.stringify({ product_id: pid, quantity: 1 }),
    { headers: authHeaders, tags: { name: 'add_cart' } });
  check(cartRes, { 'cart 200': (r) => r.status === 200 });
  thinkTime(1, 3);

  // 5) Create order / checkout — conditional 0.625 (=> 25% cumulative).
  if (!passed(0.625)) return;
  const orderRes = http.post(`${BASE}/order-service/v1/orders`,
    JSON.stringify({ address: 'k6 load test', phone_number: '0912345678',
      items: [{ product_id: pid, quantity: 1 }] }),
    { headers: authHeaders, tags: { name: 'create_order' } });
  if (!check(orderRes, { 'order 201': (r) => r.status === 201 })) return;
  const orderId = orderRes.json('data.order_id');
  thinkTime(1, 2);

  // 6) Pay — conditional 0.80 (=> 20% cumulative).
  if (!passed(0.80)) return;
  const payRes = http.post(`${BASE}/payment-service/v1/payments?orderId=${orderId}`, null,
    { headers: authHeaders, tags: { name: 'create_payment' } });
  if (!check(payRes, {
    'payment 200': (r) => r.status === 200,
    'has links': (r) => r.json('data.links') !== undefined,
  })) return;
  const links = payRes.json('data.links');
  const approve = links.find((l) => l.rel === 'approve' || l.rel === 'payer-action');
  if (!approve) return;

  // Decision mix: 90% approve, 5% cancel, 5% fail (saga success + compensation).
  const roll = Math.random();
  const decision = roll < 0.90 ? 'approve' : (roll < 0.95 ? 'cancel' : 'fail');
  const sep = approve.href.includes('?') ? '&' : '?';
  let res = http.get(toCluster(`${approve.href}${sep}decision=${decision}`),
    { redirects: 0, tags: { name: `paypal_${decision}` } });

  // Follow the 302 chain, rewriting ingress host -> gateway DNS at each hop.
  // Stop at the SPA host hop (not in-cluster reachable) with that 302 as the
  // settled result, which means the saga callback ran. Cap at 5 hops.
  let hops = 0;
  while (res.status >= 300 && res.status < 400 && hops < 5) {
    const loc = res.headers['Location'];
    if (!loc) break;
    const next = toCluster(loc);
    if (next === loc) break; // SPA host — stop at this 302
    res = http.get(next, { redirects: 0, tags: { name: 'paypal_callback' } });
    hops++;
  }
  check(res, { 'flow settled': (r) => r.status === 200 || r.status === 302 });
}
```

- [ ] **Step 3: Run inspect for `smoke` → verify it parses and selects `ramping-vus`**

Run:
```bash
docker run --rm -e PROFILE=smoke \
  -v "$PWD/k8s/apps/base/k6-stress:/scripts" \
  grafana/k6:0.54.0 inspect /scripts/storefront-flow.js | grep -o '"executor":"[a-z-]*"'
```
Expected: PASS — prints `"executor":"ramping-vus"`. (No parse error means the script is syntactically valid.)

- [ ] **Step 4: Run inspect for `soak` and `stress` → verify the executor switches**

Run:
```bash
for p in soak stress; do
  echo "PROFILE=$p:"
  docker run --rm -e PROFILE=$p \
    -v "$PWD/k8s/apps/base/k6-stress:/scripts" \
    grafana/k6:0.54.0 inspect /scripts/storefront-flow.js | grep -o '"executor":"[a-z-]*"'
done
```
Expected: PASS —
```
PROFILE=soak:
"executor":"constant-vus"
PROFILE=stress:
"executor":"ramping-arrival-rate"
```

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/base/k6-stress/storefront-flow.js
git commit -m "$(cat <<'EOF'
feat(perf): production-shaped storefront funnel k6 driver

Self-contained funnel (browse->detail->login->cart->order->pay) with
profile-selected scenarios (smoke/soak/stress) via PROFILE env. Mirrors
payment-flow.js plumbing (toCluster redirect rewrite, fail-loud setup
top-up). payment-flow.js stays the pure-saga regression baseline.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: storefront-job.yaml — parameterized k6 Job

**Files:**
- Create: `k8s/apps/base/k6-stress/storefront-job.yaml`

- [ ] **Step 1: Write the failing test (dry-run before the file exists)**

Run:
```bash
kubectl apply -f k8s/apps/base/k6-stress/storefront-job.yaml --dry-run=client
```
Expected: FAIL — `error: the path "k8s/apps/base/k6-stress/storefront-job.yaml" does not exist`.

- [ ] **Step 2: Write the Job manifest**

Create `k8s/apps/base/k6-stress/storefront-job.yaml` with exactly this content:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-storefront
  namespace: apps
  labels: { app: k6-storefront }
spec:
  # Don't auto-restart on failure — a failed threshold is real signal, not retry.
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: k6-storefront }
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          args: ["run", "-o", "experimental-prometheus-rw", "/scripts/storefront-flow.js"]
          env:
            # Profile selector. The Makefile target rewrites PROFILE_PLACEHOLDER
            # (smoke|soak|stress) via sed before apply, so this literal never runs.
            - { name: PROFILE, value: "PROFILE_PLACEHOLDER" }
            # In-cluster gateway Service DNS. The script rewrites the mock's
            # browser-facing api.microecom.local origin back to this, so no
            # hostAliases / ingress ClusterIP is needed (see storefront-flow.js).
            - { name: BASE_URL, value: "http://gateway.apps.svc.cluster.local:6868" }
            - { name: INGRESS_ORIGIN, value: "http://api.microecom.local" }
            # Real seeded catalog ObjectIds (docker/product.json -> Mongo,
            # inventoried by `make k8s-seed-inventory`). The script's default
            # (test-product-1..3) is fake in this split architecture, so this
            # override is required.
            - { name: PRODUCT_IDS, value: "67c000000000000000000001,67c000000000000000000002,67c000000000000000000003" }
            - { name: K6_PROMETHEUS_RW_SERVER_URL, value: "http://vmsingle.monitoring.svc.cluster.local:8428/api/v1/write" }
            - { name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),p(99),avg,min,max" }
          resources:
            # Higher memory ceiling than payment-job (256Mi): the stress profile
            # holds up to maxVUs=150 plus remote-write buffering.
            requests: { cpu: "200m", memory: "128Mi" }
            limits:   { cpu: "1000m", memory: "512Mi" }
          volumeMounts:
            - { name: script, mountPath: /scripts }
      volumes:
        - name: script
          configMap:
            name: k6-storefront-script
```

- [ ] **Step 3: Run the dry-run → verify the manifest is valid**

Run:
```bash
kubectl apply -f k8s/apps/base/k6-stress/storefront-job.yaml --dry-run=client
```
Expected: PASS — `job.batch/k6-storefront created (dry run)`.

- [ ] **Step 4: Verify the placeholder is present exactly once (sed target)**

Run:
```bash
grep -c PROFILE_PLACEHOLDER k8s/apps/base/k6-stress/storefront-job.yaml
```
Expected: PASS — prints `1`.

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/base/k6-stress/storefront-job.yaml
git commit -m "$(cat <<'EOF'
feat(perf): parameterized k6 storefront Job manifest

PROFILE_PLACEHOLDER is rewritten per make target; mirrors payment-job.yaml
(VM remote-write, PRODUCT_IDS override). 512Mi limit for the stress profile.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Makefile targets

**Files:**
- Modify: `Makefile` — `.PHONY` line at `:337`, help block at `:46`, and a new target block after `k8s-payment-stress-logs` (`:401`)

- [ ] **Step 1: Add the three profile targets + shared runner + logs tailer**

Add this block immediately after the `k8s-payment-stress-logs` target (after `Makefile:401`, before the `k9s` comment block):

```makefile
# Fire the production-shaped STOREFRONT funnel load Job (browse -> detail ->
# login -> cart -> order -> pay). Three profiles select the k6 scenario via
# PROFILE. The script configMap is created imperatively (stable name
# k6-storefront-script) and PROFILE_PLACEHOLDER in the Job is rewritten per
# target. Re-runnable — deletes the previous Job first (Jobs are immutable).
#   make k8s-storefront-smoke   # 50 VU / 3m fast gate
#   make k8s-storefront-soak    # 30m steady (leak/drift) — read trend on #19665
#   make k8s-storefront-stress  # open-model arrival-rate ramp to the ceiling
k8s-storefront-smoke:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=smoke
k8s-storefront-soak:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=soak
k8s-storefront-stress:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=stress

# Internal: PROFILE must be set by one of the targets above.
k8s-storefront-run:
	@kubectl -n apps delete job k6-storefront --ignore-not-found
	@kubectl -n apps create configmap k6-storefront-script \
	  --from-file=k8s/apps/base/k6-stress/storefront-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@sed 's/PROFILE_PLACEHOLDER/$(PROFILE)/' k8s/apps/base/k6-stress/storefront-job.yaml | kubectl apply -f -
	@echo "k6 storefront [$(PROFILE)] running. Watch with: make k8s-storefront-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-storefront-logs:
	@kubectl -n apps logs -f -l app=k6-storefront --tail=-1
```

- [ ] **Step 2: Register the new targets in `.PHONY`**

In `Makefile:337`, change:
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs k9s
```
to:
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs k8s-storefront-smoke k8s-storefront-soak k8s-storefront-stress k8s-storefront-run k8s-storefront-logs k9s
```

- [ ] **Step 3: Add help lines**

In the help block, change (at `Makefile:47`):
```makefile
	@echo "  make k8s-payment-stress-logs — tail k6 payment-stress output"
```
to:
```makefile
	@echo "  make k8s-payment-stress-logs — tail k6 payment-stress output"
	@echo "  make k8s-storefront-smoke    — production funnel, 50VU/3m smoke gate"
	@echo "  make k8s-storefront-soak     — production funnel, 30m soak (leak/drift)"
	@echo "  make k8s-storefront-stress   — production funnel, open-model stress ramp"
	@echo "  make k8s-storefront-logs     — tail k6 storefront output"
```

- [ ] **Step 4: Verify each target expands with the right PROFILE (dry-run make)**

Run:
```bash
make -n k8s-storefront-smoke 2>&1 | grep "sed 's/PROFILE_PLACEHOLDER"
make -n k8s-storefront-soak  2>&1 | grep "sed 's/PROFILE_PLACEHOLDER"
make -n k8s-storefront-stress 2>&1 | grep "sed 's/PROFILE_PLACEHOLDER"
```
Expected: PASS — three lines, each ending with the matching profile:
```
sed 's/PROFILE_PLACEHOLDER/smoke/' k8s/apps/base/k6-stress/storefront-job.yaml | kubectl apply -f -
sed 's/PROFILE_PLACEHOLDER/soak/' k8s/apps/base/k6-stress/storefront-job.yaml | kubectl apply -f -
sed 's/PROFILE_PLACEHOLDER/stress/' k8s/apps/base/k6-stress/storefront-job.yaml | kubectl apply -f -
```
(If `make -n` of the smoke target shows only the recursive `$(MAKE)` line and not the inner `sed`, run `make -n k8s-storefront-run PROFILE=smoke 2>&1 | grep sed` instead — GNU make propagates `-n` to sub-makes, so the inner command should print.)

- [ ] **Step 5: Verify help renders**

Run:
```bash
make help 2>/dev/null | grep storefront || make 2>/dev/null | grep storefront
```
Expected: PASS — the four `k8s-storefront-*` help lines appear.

- [ ] **Step 6: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
feat(perf): make targets for storefront funnel profiles

k8s-storefront-{smoke,soak,stress} share k8s-storefront-run, which sed-swaps
PROFILE_PLACEHOLDER and re-creates the k6-storefront-script configMap. Mirrors
the k8s-payment-stress pattern. Adds -logs tailer + help + .PHONY.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: In-cluster smoke acceptance run

This is the functional gate: it proves the funnel plumbing end-to-end (routing, auth, snake_case bodies, redirect follow, metrics). No file changes — it validates Tasks 1–3 against the live cluster. The spec's acceptance criterion for smoke is **0% errors, checks ~100%**.

**Files:** none (verification only).

- [ ] **Step 1: Ensure the cluster is up and perftest fixtures are seeded**

Run:
```bash
kubectl -n apps get pods | grep -E 'gateway|product-service|order-service|payment-service|authorization-server' | grep Running
kubectl -n apps get deploy >/dev/null && echo "cluster reachable"
```
Expected: the five services show `Running`. If perftest users were never seeded (or you're unsure), run:
```bash
make k8s-seed-perftest
```
Expected: `k8s-seed-perftest complete`. (Idempotent — safe to re-run.)

- [ ] **Step 2: Launch the smoke profile**

Run:
```bash
make k8s-storefront-smoke
```
Expected: `k6 storefront [smoke] running. Watch with: make k8s-storefront-logs`.

- [ ] **Step 3: Watch it to completion (~4.5 min) and capture the summary**

Run:
```bash
make k8s-storefront-logs
```
The tail exits when the Job pod completes. Expected in the k6 end-of-test summary:
- `setup()` did NOT throw (no `inventory top-up failed` / `admin login failed`).
- `checks` ≳ 99% (threshold `rate>0.95` met — line marked with a green check, no red ✗).
- `http_req_failed` well under 5%.
- The per-tag breakdown shows `browse`, `detail`, `login`, `add_cart`, `create_order`, `create_payment`, `paypal_*` rows — confirming every funnel stage is being reached.

If `setup()` throws on inventory top-up → `perftest_admin` lacks the ADMIN role; re-run `make k8s-seed-perftest` and retry. If `add_cart` or `create_order` checks fail en masse → re-verify the snake_case bodies in `storefront-flow.js` (`product_id`, `phone_number`) match Task 1.

- [ ] **Step 4: Confirm metrics reached VictoriaMetrics (optional but recommended)**

Run:
```bash
kubectl -n monitoring exec deploy/vmsingle -- \
  wget -qO- 'http://localhost:8428/api/v1/query?query=k6_http_reqs_total' 2>/dev/null | head -c 300 \
  || echo "vmsingle query shape differs — open Grafana #19665 and confirm the storefront run shows data"
```
Expected: a non-empty JSON result (k6 metrics present), OR the fallback note to eyeball Grafana #19665. (The exact vmsingle Deployment/pod name may differ — if the exec target is wrong, just confirm the run on Grafana dashboard #19665.)

- [ ] **Step 5: No commit** — this task produces no file changes. Record the smoke result (checks %, http_req_failed %) in the Task 5 docs update.

---

## Task 5: Documentation

**Files:**
- Modify: `docs/load-test-model-and-capacity.md` (append a section)
- Modify: `docs/performance-test-guide.md` (append a section)

- [ ] **Step 1: Append the funnel model section to `docs/load-test-model-and-capacity.md`**

Append at the end of the file:

```markdown

## Production-shaped funnel model (storefront-flow.js)

Alongside the pure-saga regression test (`payment-flow.js`, every VU pays), a
production-shaped **conversion funnel** lives in
`k8s/apps/base/k6-stress/storefront-flow.js`. Most sessions only browse; a
checkout-heavy minority pay. One script, three profiles via the `PROFILE` env.

### Per-session funnel (cumulative reach)

| Step | Endpoint | Auth | Reach | Think-time after |
|---|---|---|---|---|
| Browse page | `GET /product-service/v1/products?page&size=12` | anon | 100% | 1–4s |
| Product detail | `GET /product-service/v1/products/{id}` | anon | 60% | 2–6s |
| Login | `POST /authorization-server/v1/auth:login` | — | 40% | — |
| Add to cart | `POST /order-service/v1/shopping-carts:add-item` | Bearer | 40% | 1–3s |
| Create order | `POST /order-service/v1/orders` | Bearer | 25% | 1–2s |
| Create payment | `POST /payment-service/v1/payments?orderId` | Bearer | 20% | — |
| Approve/cancel/fail | mock-paypal 302 chain (90/5/5) | — | 20% | — |

Reach is realized via sequential conditional gates (continue probs
0.60 / 0.667 / 0.625 / 0.80). Login fires only for sessions that will add to
cart, so anonymous browsing costs no bcrypt — this is what lets the funnel
sustain more concurrent sessions than the all-pay loop.

### Profiles

| Profile | Executor | Shape | Purpose |
|---|---|---|---|
| `smoke` | `ramping-vus` | 0→50/1m, hold 50/3m, →0/30s | fast regression gate (parity with payment-flow) |
| `soak` | `constant-vus` | 30 VU for 30m (`SOAK_VUS`,`SOAK_DURATION`) | leak/drift detection |
| `stress` | `ramping-arrival-rate` | open model 10→120/s over 15m, maxVUs 150 | discover the ceiling, validate HPA |

Stress compresses think-time by 10× (`THINK_SCALE=0.1`) so the open-model
arrival rate loads the SUT instead of pinning VUs. All numeric knobs are
env-overridable (`STRESS_START_RATE`, `STRESS_PEAK_RATE`, `STRESS_DURATION`,
`STRESS_MAX_VUS`, …). Same in-cluster envelope as payment-flow (gateway Service
DNS, mock PayPal, ingress/TLS bypassed) — figures are "this code+config on this
host," not an absolute production SLA. Full suite stays under 1h.

### Latest smoke baseline

<!-- Record the Task 4 smoke run here: date, checks %, http_req_failed %. -->
```

- [ ] **Step 2: Fill in the smoke baseline line**

Replace the `<!-- Record … -->` comment with the actual numbers from the Task 4 run, e.g.:
```markdown
- **2026-06-09 smoke:** checks 99.x%, http_req_failed 0.x%, all funnel tags present (plumbing validated).
```

- [ ] **Step 3: Append the run guide to `docs/performance-test-guide.md`**

Append at the end of the file:

```markdown

## Running the production-shaped funnel (storefront-flow.js)

Prerequisites: cluster up (`make k8s-up` or equivalent) and perftest fixtures
seeded once (`make k8s-seed-perftest`).

```bash
make k8s-storefront-smoke    # ~4.5m — fast gate; expect 0% errors, checks ~100%
make k8s-storefront-soak     # 30m   — leak/drift; READ THE TREND on Grafana #19665
make k8s-storefront-stress   # ~15m  — open-model ramp; reports the discovered ceiling
make k8s-storefront-logs     # tail the running Job's k6 output + end summary
```

Override knobs inline, e.g. a shorter soak or a higher stress peak:
```bash
# edit via env in the Job, or re-run with a tweaked storefront-job.yaml:
#   SOAK_DURATION=10m SOAK_VUS=20   (soak)
#   STRESS_PEAK_RATE=200 STRESS_MAX_VUS=250   (stress)
```

### What "pass" means per profile

- **smoke** — `http_req_failed < 5%`, `checks > 95%`, `create_payment p95 < 2s`,
  `login p95 < 800ms`. k6 prints a green check per threshold.
- **soak** — `http_req_failed < 1%`, `checks > 99%`, browse/detail p95 < 500ms,
  `login p95 < 1500ms`. **k6 thresholds alone are not the soak verdict** — open
  Grafana dashboard **#19665** and confirm there is **no upward p95 or RSS trend**
  over the 30m window. A flat trend = no leak/drift (the thing the soak exists to
  catch). k6 cannot assert a trend; the eyeball on #19665 is the real gate.
- **stress** — thresholds are `abortOnFail: false`, so the ramp always completes.
  Read off the **arrival rate and concurrency at which `http_req_failed` first
  crosses 5%** — that is the discovered ceiling. Watch `kubectl -n apps get hpa -w`
  during the run to confirm order-service / auth HPA scaled.

The existing `make k8s-payment-stress` (pure-saga baseline) is unchanged and
remains the apples-to-apples regression comparison.
```

- [ ] **Step 4: Verify the docs render (no broken fences)**

Run:
```bash
grep -c '```' docs/load-test-model-and-capacity.md docs/performance-test-guide.md
```
Expected: PASS — each file reports an **even** count of fence markers (balanced code blocks).

- [ ] **Step 5: Commit**

```bash
git add docs/load-test-model-and-capacity.md docs/performance-test-guide.md
git commit -m "$(cat <<'EOF'
docs(perf): document the storefront funnel model + run guide

Funnel table, three profiles, per-profile pass criteria, and the soak
"read the trend on #19665" gate. Records the smoke baseline.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

- [ ] All five files exist/modified; `git log --oneline` shows the five commits.
- [ ] `docker run --rm -e PROFILE=stress -v "$PWD/k8s/apps/base/k6-stress:/scripts" grafana/k6:0.54.0 inspect /scripts/storefront-flow.js` prints valid options JSON with `ramping-arrival-rate`.
- [ ] Smoke run (Task 4) passed: 0% errors, checks ~100%, all funnel tags present.
- [ ] `payment-flow.js`, `payment-job.yaml`, and `k8s-payment-stress*` are untouched (`git diff main -- k8s/apps/base/k6-stress/payment-flow.js` is empty).
- [ ] Then run **superpowers:finishing-a-development-branch**.

## Spec coverage map

| Spec section | Task |
|---|---|
| §3 one script, PROFILE-selected scenarios | Task 1 (`buildScenarios`) |
| §4 funnel + conditional gates (0.60/0.667/0.625/0.80) + think-time | Task 1 (`default()`) |
| §4 think-time compression in stress (`THINK_SCALE`) | Task 1 |
| §5 three profiles + env knobs | Task 1 (`buildScenarios`, consts) |
| §6 per-profile thresholds | Task 1 (`buildThresholds`) |
| §7 setup() probe + fail-loud top-up | Task 1 (`setup()`) |
| §8 storefront-job.yaml | Task 2 |
| §8 Makefile targets + help | Task 3 |
| §8 docs updates | Task 5 |
| §11 lint via inspect; smoke acceptance | Tasks 1 & 4 |
| §9 plumbing unchanged (toCluster, VM remote-write) | Tasks 1 & 2 |
| §10 edge cases (early-gate exit, hops<5, stress non-abort) | Task 1 |
```
