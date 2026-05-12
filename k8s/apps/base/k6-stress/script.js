import http from 'k6/http';
import { check, sleep } from 'k6';

// Self-contained stress script. Targets the storefront browse path
// (PERMIT_ALL, no auth needed) so we can validate HPA + ingress wiring
// without dragging the auth flow in. Swap to /bff-service/v1/homepage
// if you want to exercise the BFF fan-out instead.
const BASE = __ENV.BASE_URL || 'http://gateway.apps.svc.cluster.local:8080';

// Ramps to 50 VUs. Each VU loops every ~1s, so peak ~50 RPS — enough
// to push 200m CPU requests past the 60% HPA target on product-service
// without melting a laptop.
export const options = {
  stages: [
    { duration: '30s', target: 20 },
    { duration: '1m',  target: 50 },
    { duration: '2m',  target: 50 },   // hold — gives HPA time to scale
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
  },
};

export default function () {
  const res = http.get(`${BASE}/product-service/v1/products?page=1&size=10`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
