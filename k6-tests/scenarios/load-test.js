import fullFlow, { setup, teardown } from '../tests/full-flow.js';
export { setup, teardown };

export const options = {
  stages: [
    { duration: '2m', target: 50 },   // Ramp up
    { duration: '11m', target: 50 },  // Steady state
    { duration: '2m', target: 0 }     // Ramp down
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:login}': ['p(95)<500'],
    'http_req_duration{name:create_order}': ['p(95)<1500'],
    'http_req_duration{name:purchase}': ['p(95)<2000'],
    'http_req_duration{name:paypal_approve}': ['p(95)<2000'],
    'http_req_duration{name:refresh_token}': ['p(95)<500']
  }
};

export default fullFlow;
