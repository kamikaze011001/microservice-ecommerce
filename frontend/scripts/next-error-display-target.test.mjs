import assert from 'node:assert';
import { pickNextPage } from './next-error-display-target.mjs';
// page A has a bare catch, B is clean → A is next.
assert.equal(pickNextPage([{ f: 'CartPage.vue', bad: true }, { f: 'HomePage.vue', bad: false }]), 'CartPage.vue');
assert.equal(pickNextPage([{ f: 'HomePage.vue', bad: false }]), null);
console.log('ok');
