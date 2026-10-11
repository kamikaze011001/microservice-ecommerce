// Runs one parsed .bru request the way Bruno does: interpolate {{vars}}, send,
// then `assert` lines, `script:post-response`, `tests` — with the same `res`,
// `bru`, `expect` (chai) and `test()` the collection's scripts are written
// against. Requests go through the portal's proxy into the chosen env's gateway.
import { expect } from 'chai'

/** {{name}} → runtime var, else env var; unknown stays as-is (so it's visible). */
export function interpolate(text, vars) {
  return (text || '').replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (m, k) => (vars[k] !== undefined ? String(vars[k]) : m))
}

// Node's Buffer, as far as the collection uses it (base64 decode of a JWT part).
const BufferShim = {
  from(s, enc) {
    const str = enc === 'base64'
      ? decodeURIComponent(escape(atob(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '='))))
      : String(s)
    return { toString: () => str }
  },
}

function makeRes(status, body, headers, ms) {
  return {
    status, body, headers, responseTime: ms,
    getStatus: () => status, getBody: () => body, getHeaders: () => headers, getResponseTime: () => ms,
    getHeader: (h) => headers[h.toLowerCase()],
  }
}

function makeBru(envVars, runtime) {
  return {
    getEnvVar: (k) => envVars[k],
    setEnvVar: (k, v) => { envVars[k] = v },
    getVar: (k) => runtime[k],
    setVar: (k, v) => { runtime[k] = v },
  }
}

function runScript(code, ctx) {
  if (!code.trim()) return null
  try {
    // eslint-disable-next-line no-new-func
    new Function('res', 'bru', 'expect', 'test', 'Buffer', 'console', code)(
      ctx.res, ctx.bru, expect, ctx.test, BufferShim, console)
    return null
  } catch (e) {
    return e.message
  }
}

// `res.status: eq 200`, `res.body.data.id: eq {{orderId}}` — Bruno's assert ops.
const OPS = {
  eq: (a, b) => a == b, // eslint-disable-line eqeqeq
  neq: (a, b) => a != b, // eslint-disable-line eqeqeq
  gt: (a, b) => a > b, gte: (a, b) => a >= b, lt: (a, b) => a < b, lte: (a, b) => a <= b,
  contains: (a, b) => String(JSON.stringify(a)).includes(String(b)),
  isDefined: (a) => a !== undefined && a !== null,
  isString: (a) => typeof a === 'string', isNumber: (a) => typeof a === 'number',
  isArray: (a) => Array.isArray(a), isNotEmpty: (a) => a != null && (a.length ?? Object.keys(a).length) > 0,
}

function evalAssert([lhs, rhs], res, vars) {
  const [op, ...rest] = rhs.split(/\s+/)
  const expectedRaw = interpolate(rest.join(' '), vars)
  let expected = expectedRaw
  try { expected = JSON.parse(expectedRaw) } catch { /* a bare string */ }
  const path = lhs.replace(/^res\./, '').split('.')
  let actual = res
  for (const p of path) actual = actual == null ? undefined : actual[p]
  const fn = OPS[op]
  if (!fn) return { name: `${lhs}: ${rhs}`, pass: false, error: `unsupported assert op "${op}"` }
  const pass = fn(actual, expected)
  return { name: `${lhs}: ${op} ${expectedRaw}`, pass, error: pass ? null : `got ${JSON.stringify(actual)}` }
}

/**
 * @param req     a parsed request (possibly edited in the console)
 * @param env     env name — requests go to /api/envs/<env>/gateway
 * @param envVars the collection environment (baseUrl is replaced by the proxy)
 * @param runtime vars set by scripts (bru.setVar), shared across a run
 */
export async function runRequest(req, env, envVars, runtime) {
  const vars = { ...envVars, ...runtime, baseUrl: `/api/envs/${env}/gateway` }
  const url = interpolate(req.url, vars)
  const headers = Object.fromEntries((req.headers || []).map(([k, v]) => [k, interpolate(v, vars)]))
  if (req.auth === 'bearer') {
    const t = interpolate(req.token, vars)
    if (t && !t.includes('{{')) headers.Authorization = `Bearer ${t}`
  }
  let body
  if (req.bodyType === 'json' && req.body.trim()) {
    body = interpolate(req.body, vars)
    headers['Content-Type'] = 'application/json'
  }

  const started = performance.now()
  let res
  try {
    const r = await fetch(url, { method: req.method, headers, body })
    const text = await r.text()
    let parsed = text
    try { parsed = text ? JSON.parse(text) : null } catch { /* not JSON */ }
    const h = {}
    r.headers.forEach((v, k) => { h[k] = v })
    res = makeRes(r.status, parsed, h, Math.round(performance.now() - started))
  } catch (e) {
    return { url, error: `request failed: ${e.message}`, results: [] }
  }

  const bru = makeBru(envVars, runtime)
  const results = []
  for (const a of req.asserts) results.push({ kind: 'assert', ...evalAssert(a, res, { ...vars, ...runtime }) })
  const scriptError = runScript(req.postScript, { res, bru, test: () => {} })
  const tests = []
  const test = (name, fn) => {
    try { fn(); tests.push({ kind: 'test', name, pass: true }) } catch (e) { tests.push({ kind: 'test', name, pass: false, error: e.message }) }
  }
  const testsError = runScript(req.tests, { res, bru, test })
  results.push(...tests)
  if (scriptError) results.push({ kind: 'script', name: 'post-response script', pass: false, error: scriptError })
  if (testsError) results.push({ kind: 'script', name: 'tests block', pass: false, error: testsError })
  return { url, method: req.method, sentBody: body, res, results }
}
