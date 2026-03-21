import fullFlow, { setup, teardown } from '../tests/full-flow.js';
export { setup, teardown };

export const options = {
  stages: [
    { duration: '3m', target: 50 },
    { duration: '3m', target: 100 },
    { duration: '3m', target: 150 },
    { duration: '3m', target: 200 },
    { duration: '5m', target: 200 },  // Hold at max
    { duration: '3m', target: 0 }
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<5000']
  }
};

export default fullFlow;
