// The portal's JSON API (snake_case on the wire, like every service here).
// Errors arrive as {"error": "<one sentence>"} with a real status.
async function call(path, options = {}) {
  const res = await fetch(path, options)
  const text = await res.text()
  let body = text
  try { body = text ? JSON.parse(text) : null } catch { /* text/plain (job logs) */ }
  if (!res.ok) throw new Error((body && body.error) || `${res.status} ${res.statusText}`)
  return body
}

const post = (path, data) => call(path, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data),
})

export const api = {
  info: () => call('/api/info'),
  tools: () => call('/api/tools'),
  envs: () => call('/api/envs'),
  history: (env, limit = 15) => call(`/api/envs/${env}/history?limit=${limit}`),
  tags: (service) => call(`/api/services/${service}/tags`),
  deploy: (env, service, tag) => post(`/api/envs/${env}/services/${service}:deploy`, { tag }),
  settings: (env, service) => call(`/api/envs/${env}/services/${service}/settings`),
  saveSettings: (env, service, body) => call(`/api/envs/${env}/services/${service}/settings`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  }),
  revertSettings: (env, service, commit) => post(`/api/envs/${env}/services/${service}/settings:revert`, { commit }),
  branches: () => call('/api/source/branches'),
  perfRuns: () => call('/api/perf-runs'),
  perfScenarios: () => call('/api/perf-scenarios'),
  perfCompare: (a, b) => call(`/api/perf-compare?a=${encodeURIComponent(a)}&b=${encodeURIComponent(b)}`),
  jobs: () => call('/api/jobs'),
  job: (name) => call(`/api/jobs/${name}`),
  jobLog: (name) => call(`/api/jobs/${name}/log`),
  startJob: (kind, target, params = {}) => post('/api/jobs', { kind, target, params }),
}

export const isActive = (status) => status === 'PENDING' || status === 'RUNNING'
