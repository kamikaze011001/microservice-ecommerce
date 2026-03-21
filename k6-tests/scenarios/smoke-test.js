import fullFlow, { setup, teardown } from '../tests/full-flow.js';
export { setup, teardown };

export const options = {
  vus: 2,
  duration: '1m',
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000']
  }
};

export default fullFlow;
