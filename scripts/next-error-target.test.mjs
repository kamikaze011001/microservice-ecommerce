import assert from 'node:assert';
import { pickNextService, serviceIsDone } from './next-error-target.mjs';

const PRIORITY = ['product-service', 'orchestrator-service'];
// product done, orchestrator not → orchestrator is next (priority beats alpha).
assert.equal(
  pickNextService(['order-service', 'product-service', 'orchestrator-service'],
    new Set(['product-service']), PRIORITY),
  'orchestrator-service',
);
// all done → null.
assert.equal(pickNextService(['a-service'], new Set(['a-service']), PRIORITY), null);

// serviceIsDone: bundle present → done regardless of throw-sites.
assert.equal(serviceIsDone(true, true), true);
assert.equal(serviceIsDone(true, false), true);
// no bundle but has throw-sites → NOT done (a real migration target).
assert.equal(serviceIsDone(false, true), false);
// no bundle and no throw-sites → done (headless service, nothing to catalog).
assert.equal(serviceIsDone(false, false), true);
console.log('ok');
