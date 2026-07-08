import type { AxeMatchers } from 'vitest-axe/matchers';

/* eslint-disable @typescript-eslint/no-empty-object-type -- module augmentation requires an empty extends */
declare module 'vitest' {
  interface Assertion extends AxeMatchers {}
  interface AsymmetricMatchersContaining extends AxeMatchers {}
}
