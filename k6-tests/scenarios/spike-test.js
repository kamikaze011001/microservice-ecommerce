import fullFlow, { setup, teardown } from '../tests/full-flow.js';
export { setup, teardown };

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    { duration: '10s', target: 100 },  // Spike!
    { duration: '3m', target: 100 },
    { duration: '10s', target: 10 },
    { duration: '2m', target: 10 },
    { duration: '30s', target: 0 }
  ],
  thresholds: {
    http_req_failed: ['rate<0.1'],
    http_req_duration: ['p(95)<5000']
  }
};

export default fullFlow;
