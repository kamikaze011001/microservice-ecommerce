import { basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const stripVue = (p) => basename(p).replace(/\.vue$/, '');

// Highest-interaction surfaces first; the rest fall back to alphabetical by path.
const PRIORITY = [
  'LoginPage',
  'RegisterPage',
  'CheckoutPage',
  'CartPage',
  'ProductDetailPage',
  'ProfilePage',
  'OrdersPage',
  'OrderDetailPage',
  'PaymentResultPage',
  'ActivatePage',
  'ForgotPasswordPage',
  'HomePage',
  'AppNav',
];

export function pickNextA11y(sources, guardedBasenames, priority) {
  const rank = (p) => {
    const i = priority.indexOf(stripVue(p));
    return i === -1 ? priority.length : i;
  };
  const unguarded = sources
    .filter((p) => !guardedBasenames.has(stripVue(p)))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return unguarded[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const testsRoot = fileURLToPath(new URL('../tests/unit', import.meta.url));

  // Page targets = pages that have a mount spec (basename match), excluding a11y specs.
  const pageSpecBasenames = new Set(
    walk(`${testsRoot}/pages`, ['.spec.ts'])
      .filter((p) => !p.endsWith('.a11y.spec.ts'))
      .map((p) => basename(p).replace(/\.spec\.ts$/, '')),
  );
  const pageSources = walk(`${srcRoot}/pages`, ['.vue'])
    .map((p) => relative(srcRoot, p))
    .filter((p) => pageSpecBasenames.has(stripVue(p)));

  // AppNav is a fixed extra target (its mount spec lives under components/).
  const targets = [...pageSources, 'components/layout/AppNav.vue'];

  // Guarded = any *.a11y.spec.ts anywhere under tests/unit, keyed by basename.
  const guarded = new Set(
    walk(testsRoot, ['.a11y.spec.ts']).map((p) => basename(p).replace(/\.a11y\.spec\.ts$/, '')),
  );

  const next = pickNextA11y(targets, guarded, PRIORITY);
  console.log(next ?? 'DONE');
}
