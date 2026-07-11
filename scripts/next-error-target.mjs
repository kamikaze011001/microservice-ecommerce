import { readFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PRIORITY = ['product-service', 'orchestrator-service'];

export function pickNextService(services, doneSet, priority) {
  const rank = (s) => {
    const i = priority.indexOf(s);
    return i === -1 ? priority.length : i;
  };
  const pending = services
    .filter((s) => !doneSet.has(s))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return pending[0] ?? null;
}

// A service is "done" for this loop if it either already ships a per-service
// bundle OR has nothing to catalog (no throw-sites under src/main). The second
// arm keeps the loop from getting stuck forever on headless services that never
// grow a bundle because they have no coded errors: event-only coordinators
// (orchestrator-service), the reactive gateway (errors go through
// ErrorResponseWriter, not `throw new …Exception`), and dev mocks
// (mock-paypal-service).
export function serviceIsDone(hasBundle, hasThrowSite) {
  return hasBundle || !hasThrowSite;
}

// Does the service throw any exception under src/main? Mirrors the gate's
// `throw new .*Exception` pattern. grep exits non-zero with no match → false.
function hasThrowSite(root, name) {
  try {
    const out = execSync(
      `grep -rlE 'throw new .*Exception' ${name}/src/main --include='*.java'`,
      { cwd: root, stdio: ['ignore', 'pipe', 'ignore'] },
    ).toString().trim();
    return out.length > 0;
  } catch {
    return false;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  // services.list is a bash array of quoted `"<name>  <ports>  <tier>"` entries.
  // Capture the name token inside the quotes; skip the SERVICES=( / ) / # lines.
  const list = readFileSync(join(root, 'scripts/services.list'), 'utf8')
    .split('\n')
    .map((l) => l.trim().match(/^"([a-z0-9-]+)\s/))
    .filter((m) => m !== null)
    .map((m) => m[1])
    // Loop scope: only *-service dirs (+ gateway). *-server dirs (eureka,
    // authorization) are intentionally out of the automated loop's reach.
    .filter((name) => name.endsWith('-service') || name === 'gateway');
  // done = ships a per-service bundle (messages/<domain>.properties, where
  // <domain> = name minus the -service suffix, matching Task 5; gateway keeps
  // "gateway") OR has no throw-sites to catalog at all.
  const done = new Set(
    list.filter((name) => {
      const hasBundle = existsSync(
        join(root, name, `src/main/resources/messages/${name.replace(/-service$/, '')}.properties`),
      );
      return serviceIsDone(hasBundle, hasThrowSite(root, name));
    }),
  );
  const next = pickNextService(list, done, PRIORITY);
  console.log(next ?? 'DONE');
}
