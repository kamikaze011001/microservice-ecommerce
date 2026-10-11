// A reader for Bruno's .bru format — the subset api-tests/ uses (and Bruno
// writes): blocks `name {` … `}` at column 0. Key/value blocks (meta, get/post…,
// auth:bearer, headers, vars, assert) are `key: value` lines; text blocks
// (body:json, script:*, tests, docs) keep their content, de-indented by 2.

const METHODS = ['get', 'post', 'put', 'patch', 'delete', 'head', 'options']
const TEXT_BLOCKS = /^(body:[a-z-]+|script:[a-z-]+|tests|docs)$/

export function parseBlocks(text) {
  const blocks = {}
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  for (let i = 0; i < lines.length; i++) {
    const open = lines[i].match(/^([a-z][a-z0-9:-]*)\s*\{\s*$/i)
    if (!open) continue
    const name = open[1]
    const body = []
    for (i++; i < lines.length && lines[i] !== '}'; i++) body.push(lines[i])
    blocks[name] = TEXT_BLOCKS.test(name)
      ? body.map((l) => l.replace(/^ {2}/, '')).join('\n').trim()
      : keyValues(body)
  }
  return blocks
}

function keyValues(lines) {
  const out = []
  for (const l of lines) {
    const t = l.trim()
    if (!t || t.startsWith('#')) continue
    const at = t.indexOf(':')
    if (at < 0) continue
    // `assert` keys can contain dots and colons' left side only — split on the FIRST ": ".
    const sep = t.indexOf(': ') >= 0 ? t.indexOf(': ') : at
    out.push([t.slice(0, sep).trim(), t.slice(sep + 1).trim()])
  }
  return out
}

const kv = (pairs = []) => Object.fromEntries(pairs)

/** One request file → a request the console can show, edit and run. */
export function parseRequest(path, text) {
  const b = parseBlocks(text)
  const meta = kv(b.meta)
  const method = METHODS.find((m) => b[m]) || 'get'
  const http = kv(b[method])
  return {
    path,
    name: meta.name || path.split('/').pop().replace(/\.bru$/, ''),
    seq: Number(meta.seq || 0),
    method: method.toUpperCase(),
    url: http.url || '',
    bodyType: http.body || 'none',
    auth: http.auth || 'none',
    token: kv(b['auth:bearer']).token || '',
    headers: b.headers || [],
    body: b['body:json'] || '',
    asserts: b.assert || [],
    preScript: b['script:pre-request'] || '',
    postScript: b['script:post-response'] || '',
    tests: b.tests || '',
    docs: b.docs || '',
  }
}

/**
 * The files the portal serves → { collection docs, environments, folders:[{name, seq, requests}] },
 * ordered the way Bruno runs them: folders by seq (then name), requests by seq.
 */
export function parseCollection(files) {
  const folders = new Map()
  const environments = {}
  let docs = ''
  for (const f of files) {
    const parts = f.path.split('/')
    if (f.path === 'collection.bru') { docs = parseBlocks(f.content).docs || ''; continue }
    if (parts[0] === 'environments') {
      environments[parts[1].replace(/\.bru$/, '')] = kv(parseBlocks(f.content).vars)
      continue
    }
    const folder = parts.length > 1 ? parts.slice(0, -1).join('/') : ''
    if (!folders.has(folder)) folders.set(folder, { name: folder || '(root)', seq: 0, requests: [] })
    if (parts[parts.length - 1] === 'folder.bru') {
      const meta = kv(parseBlocks(f.content).meta)
      folders.get(folder).seq = Number(meta.seq || 0)
      if (meta.name) folders.get(folder).label = meta.name
      continue
    }
    folders.get(folder).requests.push(parseRequest(f.path, f.content))
  }
  const list = [...folders.values()]
    .map((g) => ({ ...g, requests: g.requests.sort((a, b) => a.seq - b.seq) }))
    .sort((a, b) => (a.seq - b.seq) || a.name.localeCompare(b.name))
  return { docs, environments, folders: list }
}
