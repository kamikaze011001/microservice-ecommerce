import assert from 'node:assert';
import { pickNextService } from './next-error-target.mjs';

const PRIORITY = ['product-service', 'orchestrator-service'];
// product done, orchestrator not → orchestrator is next (priority beats alpha).
assert.equal(
  pickNextService(['order-service', 'product-service', 'orchestrator-service'],
    new Set(['product-service']), PRIORITY),
  'orchestrator-service',
);
// all done → null.
assert.equal(pickNextService(['a-service'], new Set(['a-service']), PRIORITY), null);
console.log('ok');
