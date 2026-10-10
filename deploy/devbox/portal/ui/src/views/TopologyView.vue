<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api'
import { remember } from '../format'

// The system as developers think about it: services and how they call each
// other — not Kubernetes objects (that's Argo CD's view). Edges are the real
// ones from the code: gateway routes, Feign (HTTP), gRPC stubs, the Kafka saga.
const router = useRouter()
const envs = ref([])
const env = ref(remember.get('topology.env', 'prod-like'))
const error = ref('')

const NODES = {
  frontend:               { x: 500, y: 50,  label: 'frontend', note: 'SPA (Caddy)' },
  gateway:                { x: 500, y: 150, label: 'gateway', note: 'auth · routing' },
  'authorization-server': { x: 95,  y: 270, label: 'authorization', note: 'MySQL · Redis' },
  'bff-service':          { x: 260, y: 270, label: 'bff', note: 'aggregates' },
  'product-service':      { x: 425, y: 270, label: 'product', note: 'MongoDB' },
  'order-service':        { x: 590, y: 270, label: 'order', note: 'MySQL · Redis · Mongo events' },
  'payment-service':      { x: 755, y: 270, label: 'payment', note: 'MySQL' },
  'inventory-service':    { x: 905, y: 270, label: 'inventory', note: 'MySQL · Redis · gRPC' },
  'mock-paypal-service':  { x: 755, y: 400, label: 'mock PayPal', note: 'stands in for PayPal' },
  'orchestrator-service': { x: 425, y: 400, label: 'orchestrator', note: 'order saga · MySQL' },
  kafka:                  { x: 425, y: 520, label: 'Kafka', note: 'saga topics + Mongo CDC', infra: true },
}
const EDGES = [
  ['frontend', 'gateway', 'http'],
  ...['authorization-server', 'bff-service', 'product-service', 'order-service', 'payment-service', 'inventory-service']
    .map((s) => ['gateway', s, 'http']),
  ['bff-service', 'product-service', 'http', -40], ['bff-service', 'order-service', 'http', -70], ['bff-service', 'payment-service', 'http', -100],
  ['bff-service', 'inventory-service', 'grpc', 130], ['order-service', 'inventory-service', 'grpc', 40],
  ['payment-service', 'mock-paypal-service', 'http'],
  ['order-service', 'kafka', 'kafka'], ['payment-service', 'kafka', 'kafka'],
  ['kafka', 'orchestrator-service', 'kafka'],
  ['kafka', 'inventory-service', 'kafka'], ['kafka', 'product-service', 'kafka', 60],
]

const services = ref({})
const W = 150
const H = 54

async function load() {
  try {
    const all = await api.envs()
    envs.value = all.map((e) => e.name)
    const e = all.find((x) => x.name === env.value) || all[0]
    if (e) { env.value = e.name; services.value = Object.fromEntries(e.services.map((s) => [s.name, s])) }
    error.value = ''
  } catch (err) { error.value = err.message }
}

function state(key) {
  const s = services.value[key]
  if (!s) return NODES[key].infra ? 'infra' : 'unknown'
  if (s.health === 'Healthy' && s.sync === 'Synced') return 'ok'
  if (s.health === 'Progressing' || s.sync === 'OutOfSync') return 'warn'
  return 'bad'
}
function edgePath([a, b, , bend = 0]) {
  const A = NODES[a]; const B = NODES[b]
  const y1 = A.y + (B.y > A.y ? H / 2 : B.y < A.y ? -H / 2 : 0)
  const y2 = B.y + (A.y > B.y ? H / 2 : A.y < B.y ? -H / 2 : 0)
  const x1 = A.x; const x2 = B.x
  if (A.y === B.y) {   // same row: arc above/below the boxes
    const dir = bend >= 0 ? 1 : -1
    const yy = A.y + dir * (H / 2)
    const cy = yy + (bend || 40)
    return `M${x1},${yy} Q${(x1 + x2) / 2},${cy} ${x2},${yy}`
  }
  return `M${x1},${y1} C${x1},${(y1 + y2) / 2 + bend} ${x2},${(y1 + y2) / 2 - bend} ${x2},${y2}`
}
const version = (key) => services.value[key]?.desired_tag || ''
const health = (key) => services.value[key] ? `${services.value[key].sync} · ${services.value[key].health}` : ''
const counts = computed(() => {
  const keys = Object.keys(NODES).filter((k) => !NODES[k].infra)
  return { ok: keys.filter((k) => state(k) === 'ok').length, all: keys.length }
})

function open(key) {
  if (services.value[key]) router.push(`/envs/${env.value}/services/${key}/settings`)
}
function pick(v) { env.value = v; remember.set('topology.env', v); load() }

let timer
onMounted(() => { load(); timer = setInterval(load, 10000) })
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <div class="head">
    <div>
      <h1>Topology</h1>
      <p class="muted">How the services of <b>{{ env }}</b> call each other, with each one's live version and health.
        Click a service for its settings &amp; history.</p>
    </div>
    <label class="envpick">Env
      <select :value="env" @change="(e) => pick(e.target.value)"><option v-for="e in envs" :key="e">{{ e }}</option></select>
    </label>
  </div>
  <p v-if="error" class="error">{{ error }}</p>

  <div class="panel diagram">
    <div class="legend">
      <span><i class="l http"></i>HTTP</span><span><i class="l grpc"></i>gRPC</span><span><i class="l kafka"></i>Kafka (async)</span>
      <span class="sp"></span><span class="pill" :class="counts.ok === counts.all ? 'good' : 'warn'">{{ counts.ok }}/{{ counts.all }} healthy</span>
    </div>
    <svg viewBox="0 0 1000 580" role="img" :aria-label="`Service topology of ${env}`">
      <defs>
        <marker v-for="k in ['http', 'grpc', 'kafka']" :id="`arrow-${k}`" :key="k" viewBox="0 0 10 10" refX="9" refY="5"
                markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0,0 L10,5 L0,10 z" :class="`fill-${k}`" />
        </marker>
      </defs>
      <path v-for="(e, i) in EDGES" :key="i" :d="edgePath(e)" :class="['edge', e[2]]" :marker-end="`url(#arrow-${e[2]})`" />
      <g v-for="(n, key) in NODES" :key="key" :class="['node', state(key), { link: services[key] }]"
         :transform="`translate(${n.x - W / 2},${n.y - H / 2})`" @click="open(key)">
        <title>{{ key }} {{ version(key) }} {{ health(key) }}</title>
        <rect :width="W" :height="H" rx="10" />
        <circle cx="14" cy="16" r="5" class="dot" />
        <text x="26" y="20" class="name">{{ n.label }}</text>
        <text x="12" y="36" class="ver">{{ version(key) || (n.infra ? 'shared infra' : '') }}</text>
        <text x="12" y="48" class="note">{{ n.note }}</text>
      </g>
    </svg>
  </div>
  <p class="muted small">Async flow: order/payment write events to MongoDB → Kafka Connect (CDC) → Kafka → the orchestrator
    drives the saga → inventory &amp; product react. Databases are shared infra with one database per env.</p>
</template>

<style scoped>
.head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
.head p { margin: 4px 0 0; }
.envpick { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--ink2); }
.diagram { padding: 10px 12px; }
.legend { display: flex; gap: 16px; align-items: center; font-size: 12.5px; color: var(--ink2); padding: 2px 4px 8px; flex-wrap: wrap; }
.legend .sp { flex: 1; }
.l { display: inline-block; width: 22px; height: 0; border-top: 2px solid; vertical-align: middle; margin-right: 6px; }
.l.http { border-color: #8a8378; } .l.grpc { border-color: #3b6fd1; } .l.kafka { border-color: #c4841a; border-top-style: dashed; }
svg { width: 100%; height: auto; display: block; }
.edge { fill: none; stroke-width: 1.6; opacity: .75; }
.edge.http { stroke: #8a8378; } .edge.grpc { stroke: #3b6fd1; } .edge.kafka { stroke: #c4841a; stroke-dasharray: 5 4; }
.fill-http { fill: #8a8378; } .fill-grpc { fill: #3b6fd1; } .fill-kafka { fill: #c4841a; }
.node rect { fill: var(--panel); stroke: var(--line); stroke-width: 1.5; }
.node.link { cursor: pointer; }
.node.link:hover rect { stroke: var(--acc); }
.node .dot { fill: var(--ink2); }
.node.ok .dot { fill: var(--good); } .node.warn .dot { fill: var(--warn); } .node.bad .dot { fill: var(--bad); }
.node.bad rect { stroke: var(--bad); }
.node.infra rect { fill: var(--panel2); stroke-dasharray: 4 3; }
.name { font-size: 13.5px; font-weight: 700; fill: var(--ink); }
.ver { font-size: 11px; font-family: var(--mono); fill: var(--ink2); }
.note { font-size: 10px; fill: var(--ink2); }
.small { font-size: 12.5px; }
.error { color: var(--bad); }
</style>
