import { readFileSync, existsSync } from 'node:fs';
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
  // A service is "done" once it ships a per-service bundle: messages/<domain>.properties,
  // where <domain> = name minus the -service suffix (product-service → product.properties,
  // matching Task 5). gateway has no -service suffix, so its bundle name stays "gateway".
  const done = new Set(
    list.filter((name) => existsSync(join(root, name, `src/main/resources/messages/${name.replace(/-service$/, '')}.properties`))),
  );
  const next = pickNextService(list, done, PRIORITY);
  console.log(next ?? 'DONE');
}
