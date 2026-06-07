import http from 'k6/http';
import { check, sleep } from 'k6';

// Self-contained in-cluster payment-saga stress driver for mock-paypal-service.
// Runs login -> create order -> create payment -> approve(decision) against the
// gateway Service DNS, driving a 90/5/5 approve/cancel/fail mix so the saga's
// success AND compensation paths are exercised under load. No external imports
// (k6 ConfigMaps mount a single flat file), so everything is inlined here.
//
// Reachability — why no hostAliases: the mock embeds the BROWSER-facing ingress
// host (api.microecom.local) in the approve link, and payment-service redirects
// to PAYPAL_TUNNEL_URL (also api.microecom.local). An in-cluster pod can't
// resolve that host. Instead of hostAliases mapping it to the ingress-nginx
// ClusterIP (which is dynamic and can't be hardcoded in a committed manifest),
// we rewrite any api.microecom.local origin back to the in-cluster gateway
// Service DNS at every redirect hop — same destination, nothing to template.
//
// Prerequisites in the cluster: the perftest users (seeded by `make
// k8s-seed-perftest` / the 06-perftest-seed Job) and the PRODUCT_IDS must exist.
// The script fails loudly in setup() otherwise.

const BASE = __ENV.BASE_URL || 'http://gateway.apps.svc.cluster.local:6868';
const INGRESS_ORIGIN = __ENV.INGRESS_ORIGIN || 'http://api.microecom.local';

const ADMIN_USER = __ENV.ADMIN_USER || 'perftest_admin';
const ADMIN_PASS = __ENV.ADMIN_PASS || 'Admin@123456';
const USER_PASS = __ENV.USER_PASS || 'Test@123456';
const USER_COUNT = parseInt(__ENV.USER_COUNT || '100', 10);
const PRODUCT_IDS = (__ENV.PRODUCT_IDS || 'test-product-1,test-product-2,test-product-3')
  .split(',').map((s) => s.trim());

export const options = {
  // SLO bar: hold 50 VUs for 3m. The held, error-free VU level is the
  // sustained-throughput figure to quote. If the kind cluster saturates on a
  // laptop, step the hold target down to 30/20 and re-run.
  stages: [
    { duration: '1m',  target: 50 },   // ramp to the SLO load
    { duration: '3m',  target: 50 },   // HOLD — the sustained-throughput window
    { duration: '30s', target: 0 },    // ramp down
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
    'http_req_duration{name:create_payment}': ['p(95)<2000'],
    'http_req_duration{name:login}': ['p(95)<800'],
  },
};

// Rewrite the browser-facing ingress origin to the in-cluster gateway.
function toCluster(url) {
  return url.replace(INGRESS_ORIGIN, BASE);
}

export function setup() {
  // Probe a routed PERMIT_ALL business endpoint (the gateway does NOT route
  // /actuator/** — management lives on a separate port). Storefront browse is
  // PERMIT_ALL, so this confirms the gateway + product-service path is up.
  const health = http.get(`${BASE}/product-service/v1/products?page=1&size=1`);
  if (health.status !== 200) {
    throw new Error(`gateway/product-service not reachable: ${health.status} ${health.body}`);
  }

  // Admin login + top up inventory for the test products so orders can be placed.
  const adminRes = http.post(`${BASE}/authorization-server/v1/auth:login`,
    JSON.stringify({ username: ADMIN_USER, password: ADMIN_PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'admin_login' } });
  if (adminRes.status !== 200) {
    throw new Error(`admin login failed (${adminRes.status}); seed perftest users first: ${adminRes.body}`);
  }
  const adminToken = adminRes.json('data.access_token');
  for (const pid of PRODUCT_IDS) {
    http.patch(`${BASE}/inventory-service/v1/inventories/${pid}`,
      JSON.stringify({ quantity: 1000000, is_add: true }),
      { headers: { 'Authorization': `Bearer ${adminToken}`, 'Content-Type': 'application/json' },
        tags: { name: 'setup_inventory' } });
  }
  return {};
}

export default function () {
  const vu = __VU;
  const username = `perftest_user_${(vu % USER_COUNT) + 1}`;

  // 1) Login
  const loginRes = http.post(`${BASE}/authorization-server/v1/auth:login`,
    JSON.stringify({ username, password: USER_PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } });
  if (!check(loginRes, { 'login 200': (r) => r.status === 200 })) {
    sleep(1);
    return;
  }
  const token = loginRes.json('data.access_token');
  const authHeaders = { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' };

  // 2) Create order
  const pid = PRODUCT_IDS[Math.floor(Math.random() * PRODUCT_IDS.length)];
  const orderRes = http.post(`${BASE}/order-service/v1/orders`,
    JSON.stringify({ address: 'k6 load test', phone_number: '0912345678',
      items: [{ product_id: pid, quantity: 1 }] }),
    { headers: authHeaders, tags: { name: 'create_order' } });
  if (!check(orderRes, { 'order 201': (r) => r.status === 201 })) {
    sleep(1);
    return;
  }
  const orderId = orderRes.json('data.order_id');

  // 3) Create payment -> approve link
  const payRes = http.post(`${BASE}/payment-service/v1/payments?orderId=${orderId}`, null,
    { headers: authHeaders, tags: { name: 'create_payment' } });
  if (!check(payRes, {
    'payment 200': (r) => r.status === 200,
    'has links': (r) => r.json('data.links') !== undefined,
  })) {
    sleep(1);
    return;
  }
  const links = payRes.json('data.links');
  const approve = links.find((l) => l.rel === 'approve' || l.rel === 'payer-action');
  if (!approve) {
    sleep(1);
    return;
  }

  // 4) Decision mix: 90% approve, 5% cancel, 5% fail
  const roll = Math.random();
  const decision = roll < 0.90 ? 'approve' : (roll < 0.95 ? 'cancel' : 'fail');
  const sep = approve.href.includes('?') ? '&' : '?';
  let res = http.get(toCluster(`${approve.href}${sep}decision=${decision}`),
    { redirects: 0, tags: { name: `paypal_${decision}` } });

  // Manually follow the 302 chain, rewriting the ingress host to gateway DNS
  // at each hop (the mock + payment-service emit absolute api.microecom.local
  // URLs). The chain's FINAL hop is payment-service's 302 to the SPA host
  // (http://microecom.local/payment/success) — a browser-only host we don't
  // rewrite or follow; we stop there with that 302 as the settled result,
  // which means the saga callback ran.
  let hops = 0;
  while (res.status >= 300 && res.status < 400 && hops < 5) {
    const loc = res.headers['Location'];
    if (!loc) break;
    const next = toCluster(loc);
    if (next === loc) break; // not in-cluster reachable (SPA host) — stop at this 302
    res = http.get(next, { redirects: 0, tags: { name: 'paypal_callback' } });
    hops++;
  }
  check(res, { 'flow settled': (r) => r.status === 200 || r.status === 302 });

  sleep(1);
}
