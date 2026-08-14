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
        preAllocatedVUs: Math.min(50, STRESS_MAX_VUS),
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

const VALID_PROFILES = ['smoke', 'soak', 'stress'];
if (!VALID_PROFILES.includes(PROFILE)) {
  throw new Error(`Unknown PROFILE "${PROFILE}" — must be one of: ${VALID_PROFILES.join(', ')}`);
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
  // Snapshot the price the shopper sees on the detail page; the cart line stores
  // this snapshot, so a later catalog price change can't mutate an in-flight cart.
  // Fall back to a nominal price if a transient detail miss left it null.
  const price = detailRes.json('data.price') || 9.99;
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
    JSON.stringify({ product_id: pid, quantity: 1, price }),
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
