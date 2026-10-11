<script setup>
import { computed } from 'vue'

// What a perf run will do, as k6 resolved it from the script (k6 inspect) —
// the load shape as a chart, the pass/fail thresholds in words.
const props = defineProps({ settings: { type: Object, required: true } })

/** k6 durations ("1m30s", "30s", "2h0m0s") → seconds. */
function seconds(d) {
  if (!d) return 0
  let s = 0
  for (const [, n, u] of String(d).matchAll(/(\d+(?:\.\d+)?)(ms|h|m|s)/g)) {
    s += Number(n) * ({ h: 3600, m: 60, s: 1, ms: 0.001 }[u])
  }
  return s
}
const fmt = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.round((s % 3600) / 60)}m`
  : s >= 60 ? `${Math.floor(s / 60)}m${s % 60 ? ` ${Math.round(s % 60)}s` : ''}` : `${Math.round(s)}s`)

/** Each k6 scenario → a load curve [(t, value)], its unit, and a one-line summary. */
const scenarios = computed(() => Object.entries(props.settings.scenarios || {}).map(([name, sc]) => {
  const ex = sc.executor
  let points = []
  let unit = 'virtual users'
  let summary = ''
  if (ex === 'constant-vus') {
    const d = seconds(sc.duration)
    points = [[0, sc.vus], [d, sc.vus]]
    summary = `${sc.vus} users looping for ${fmt(d)}`
  } else if (ex === 'ramping-vus') {
    let t = 0
    points = [[0, sc.startVUs || 0]]
    for (const st of sc.stages || []) { t += seconds(st.duration); points.push([t, st.target]) }
    const peak = Math.max(...points.map((p) => p[1]))
    summary = `ramps users ${(sc.stages || []).map((st) => `→ ${st.target} over ${fmt(seconds(st.duration))}`).join(', ')} (peak ${peak})`
  } else if (ex === 'ramping-arrival-rate' || ex === 'constant-arrival-rate') {
    unit = `requests / ${sc.timeUnit || '1s'}`
    if (ex === 'constant-arrival-rate') {
      const d = seconds(sc.duration)
      points = [[0, sc.rate], [d, sc.rate]]
      summary = `${sc.rate} iterations per ${sc.timeUnit || '1s'} for ${fmt(d)}`
    } else {
      let t = 0
      points = [[0, sc.startRate || 0]]
      for (const st of sc.stages || []) { t += seconds(st.duration); points.push([t, st.target]) }
      summary = `ramps the arrival rate ${sc.startRate || 0} → ${Math.max(...points.map((p) => p[1]))} per ${sc.timeUnit || '1s'} over ${fmt(t)}`
    }
    summary += ` · up to ${sc.maxVUs || sc.preAllocatedVUs} users`
  } else if (ex === 'per-vu-iterations' || ex === 'shared-iterations') {
    summary = `${sc.iterations} iterations across ${sc.vus} users`
  } else {
    summary = ex
  }
  const total = points.length ? points[points.length - 1][0] : 0
  return { name, executor: ex, points, unit, summary, total }
}))

const totalTime = computed(() => Math.max(0, ...scenarios.value.map((s) => s.total)))
const totalLabel = computed(() => (totalTime.value ? `≈ ${fmt(totalTime.value)}` : 'an unknown time'))

/** SVG path for a load curve in a 300×80 box. */
function path(points) {
  if (points.length < 2) return ''
  const maxT = points[points.length - 1][0] || 1
  const maxV = Math.max(1, ...points.map((p) => p[1]))
  const xy = points.map(([t, v]) => [4 + (t / maxT) * 292, 76 - (v / maxV) * 66])
  return `M${xy.map((p) => p.join(',')).join(' L')}`
}
const peak = (points) => Math.max(0, ...points.map((p) => p[1]))

/** k6 threshold expressions → what they mean. */
const METRICS = {
  http_req_failed: 'failed requests', checks: 'checks passing', http_req_duration: 'response time',
  iteration_duration: 'one full iteration',
}
function explain(metric, cond) {
  const c = typeof cond === 'string' ? cond : cond.threshold
  const abort = typeof cond === 'object' && cond.abortOnFail === false ? ' (reported, does not stop the run)' : ''
  const [, base, tag] = metric.match(/^([a-z_]+)(?:\{(.+)\})?$/) || [, metric]
  const what = (METRICS[base] || base) + (tag ? ` of ${tag.replace(/^name:/, '')}` : '')
  let m = c.match(/^rate\s*([<>]=?)\s*([\d.]+)$/)
  if (m) return `${what}: ${m[1].startsWith('<') ? 'under' : 'over'} ${Math.round(Number(m[2]) * 1000) / 10}%${abort}`
  m = c.match(/^p\((\d+(?:\.\d+)?)\)\s*([<>]=?)\s*([\d.]+)$/)
  if (m) return `${what}: ${m[1]}% of requests ${m[2].startsWith('<') ? 'faster than' : 'slower than'} ${m[3]} ms${abort}`
  m = c.match(/^(avg|med|max|min)\s*([<>]=?)\s*([\d.]+)$/)
  if (m) return `${what}: ${m[1]} ${m[2]} ${m[3]} ms${abort}`
  return `${what}: ${c}${abort}`
}
const thresholds = computed(() => Object.entries(props.settings.thresholds || {})
  .flatMap(([metric, conds]) => conds.map((c) => ({ metric, text: explain(metric, c), raw: typeof c === 'string' ? c : c.threshold }))))
</script>

<template>
  <div class="settings">
    <div class="top">
      <div>
        <h3>What this run does</h3>
        <p class="desc">{{ settings.description || 'No description in the script.' }}</p>
        <p class="muted small"><code>deploy/k6-stress/{{ settings.script }}</code>
          <template v-if="settings.overrides"> · started with <code>{{ settings.overrides }}</code></template>
          · takes <b>{{ totalLabel }}</b> plus setup</p>
      </div>
    </div>

    <div class="grid">
      <div v-for="s in scenarios" :key="s.name" class="card">
        <h4>Load shape <span class="muted">· {{ s.executor }}</span></h4>
        <p class="small">{{ s.summary }}</p>
        <svg v-if="s.points.length > 1" viewBox="0 0 300 92" class="chart" role="img" :aria-label="s.summary">
          <path :d="path(s.points) + ` L296,76 L4,76 Z`" class="area" />
          <path :d="path(s.points)" class="line" />
          <text x="4" y="10" class="lbl">{{ peak(s.points) }} {{ s.unit }}</text>
          <text x="296" y="90" text-anchor="end" class="lbl">{{ fmt(s.total) }}</text>
          <text x="4" y="90" class="lbl">0</text>
        </svg>
      </div>

      <div class="card">
        <h4>Pass / fail thresholds</h4>
        <p class="muted small">The run is marked FAILED if any of these is broken.</p>
        <ul class="thr">
          <li v-for="t in thresholds" :key="t.metric + t.raw" :title="`${t.metric}: ${t.raw}`">{{ t.text }}</li>
          <li v-if="!thresholds.length" class="muted">None — the run can't fail on numbers.</li>
        </ul>
      </div>

      <div class="card">
        <h4>Requests it makes</h4>
        <p class="muted small">These names are the rows of a comparison.</p>
        <div class="reqs"><code v-for="r in settings.requests" :key="r">{{ r }}</code></div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.settings { border-top: 1px solid var(--line); padding-top: 12px; margin-top: 4px; }
h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .05em; color: var(--ink2); margin: 0 0 4px; }
h4 { margin: 0 0 4px; font-size: 13.5px; }
.desc { white-space: pre-line; margin: 0 0 6px; font-size: 13.5px; }
.small { font-size: 12.5px; margin: 0 0 6px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; margin-top: 10px; }
.card { background: var(--panel2); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
.chart { width: 100%; height: auto; display: block; margin-top: 4px; }
.area { fill: color-mix(in srgb, var(--acc) 18%, transparent); }
.line { fill: none; stroke: var(--acc); stroke-width: 2; }
.lbl { font-size: 9px; fill: var(--ink2); font-family: var(--mono); }
.thr { margin: 0; padding-left: 18px; font-size: 13px; }
.thr li { margin: 3px 0; }
.reqs { display: flex; flex-wrap: wrap; gap: 6px; }
.reqs code { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 1px 6px; }
</style>
