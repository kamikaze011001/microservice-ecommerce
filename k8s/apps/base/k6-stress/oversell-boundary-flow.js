import http from 'k6/http';
import { check, sleep } from 'k6';

// THROWAWAY boundary test for the oversell fix. Same payment saga as
// payment-flow.js, but: (1) targets ONE product, (2) does NOT top up stock in
// setup() — so the product's pre-seeded LOW stock is the boundary, and (3) high
// concurrency to stress the reserve→decrement interleave that exposed the
// slave-read oversell. Pass after the fix = final SUM(product_quantity_history)
// for the target floors at 0 (never negative).

const BASE = __ENV.BASE_URL || 'http://gateway.apps.svc.cluster.local:6868';
const INGRESS_ORIGIN = __ENV.INGRESS_ORIGIN || 'http://api.microecom.local';
const USER_PASS = __ENV.USER_PASS || 'Test@123456';
const USER_COUNT = parseInt(__ENV.USER_COUNT || '100', 10);
const PRODUCT_ID = __ENV.PRODUCT_ID;  // required — the single low-stock target

export const options = {
  scenarios: {
    boundary: { executor: 'constant-vus', vus: 50, duration: '90s' },
  },
};

function toCluster(url) { return url.replace(INGRESS_ORIGIN, BASE); }

export function setup() {
  if (!PRODUCT_ID) throw new Error('PRODUCT_ID env is required');
  const health = http.get(`${BASE}/product-service/v1/products?page=1&size=1`);
  if (health.status !== 200) throw new Error(`gateway not reachable: ${health.status}`);
  // intentionally NO inventory top-up — we want to hit the stock boundary
  return {};
}

export default function () {
  const username = `perftest_user_${(__VU % USER_COUNT) + 1}`;
  const loginRes = http.post(`${BASE}/authorization-server/v1/auth:login`,
    JSON.stringify({ username, password: USER_PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } });
  if (!check(loginRes, { 'login 200': (r) => r.status === 200 })) { sleep(0.5); return; }
  const token = loginRes.json('data.access_token');
  const h = { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' };

  const orderRes = http.post(`${BASE}/order-service/v1/orders`,
    JSON.stringify({ address: 'boundary', phone_number: '0912345678',
      items: [{ product_id: PRODUCT_ID, quantity: 1 }] }),
    { headers: h, tags: { name: 'create_order' } });
  // out-of-stock rejection (InvalidProductQuantity) is EXPECTED once depleted —
  // that's correct behavior, not a failure. Only proceed to pay on a real order.
  if (orderRes.status !== 201) { sleep(0.3); return; }
  const orderId = orderRes.json('data.order_id');

  const payRes = http.post(`${BASE}/payment-service/v1/payments?orderId=${orderId}`, null,
    { headers: h, tags: { name: 'create_payment' } });
  if (payRes.status !== 200) { sleep(0.3); return; }
  const links = payRes.json('data.links');
  const approve = links && links.find((l) => l.rel === 'approve' || l.rel === 'payer-action');
  if (!approve) { sleep(0.3); return; }

  // always approve — maximize decrements to drive depletion
  const sep = approve.href.includes('?') ? '&' : '?';
  let res = http.get(toCluster(`${approve.href}${sep}decision=approve`),
    { redirects: 0, tags: { name: 'paypal_approve' } });
  let hops = 0;
  while (res.status >= 300 && res.status < 400 && hops < 5) {
    const loc = res.headers['Location']; if (!loc) break;
    const next = toCluster(loc); if (next === loc) break;
    res = http.get(next, { redirects: 0, tags: { name: 'paypal_callback' } });
    hops++;
  }
  sleep(0.3);
}
