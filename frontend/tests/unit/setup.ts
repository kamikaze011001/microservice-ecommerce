import '@testing-library/vue';
import '@testing-library/jest-dom/vitest';
import * as axeMatchers from 'vitest-axe/matchers';
import { expect } from 'vitest';

expect.extend(axeMatchers);

// Reka UI (and Radix) use Pointer Events API internally.
// happy-dom doesn't implement hasPointerCapture / setPointerCapture / releasePointerCapture,
// so we stub them to prevent TypeError crashes in Select/Dialog tests.
Element.prototype.hasPointerCapture = Element.prototype.hasPointerCapture ?? (() => false);
Element.prototype.setPointerCapture = Element.prototype.setPointerCapture ?? (() => {});
Element.prototype.releasePointerCapture = Element.prototype.releasePointerCapture ?? (() => {});
