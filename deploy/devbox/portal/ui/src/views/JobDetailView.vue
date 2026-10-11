<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { api, isActive } from '../api'
import { ansiToHtml, duration, envUrls, when } from '../format'
import StatusPill from '../components/StatusPill.vue'

const props = defineProps({ name: { type: String, required: true } })

const job = ref(null)
const log = ref('')
const error = ref('')
const follow = ref(true)
const logEl = ref(null)
let timer

const html = computed(() => ansiToHtml(log.value))
const created = computed(() => job.value?.kind === 'env-create' && job.value?.status === 'SUCCEEDED')

async function load() {
  try {
    const [j, l] = await Promise.all([api.job(props.name), api.jobLog(props.name)])
    job.value = j
    log.value = l || ''
    error.value = ''
    if (!isActive(j.status)) clearInterval(timer)
  } catch (e) {
    error.value = e.message
  }
}

watch(log, async () => {
  if (!follow.value) return
  await nextTick()
  if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
})

function onScroll() {
  const el = logEl.value
  follow.value = el.scrollHeight - el.scrollTop - el.clientHeight < 40
}

onMounted(() => { load(); timer = setInterval(load, 2000) })
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <RouterLink to="/jobs" class="back muted">‹ All jobs</RouterLink>
  <p v-if="error" class="error">{{ error }}</p>
  <template v-if="job">
    <div class="head">
      <div>
        <h1>{{ job.title }} <code class="target">{{ job.target }}</code></h1>
        <div class="muted meta">
          <StatusPill :value="job.status" />
          started {{ when(job.started_at) }} · {{ duration(job.started_at, job.finished_at) }}
          <span v-if="job.status === 'RUNNING'"> and counting</span>
        </div>
      </div>
      <div class="actions">
        <template v-if="created">
          <a class="btn" :href="envUrls(job.target).web" target="_blank" rel="noopener">Open storefront ↗</a>
          <RouterLink class="btn primary" to="/envs">Go to environments ›</RouterLink>
        </template>
        <RouterLink v-else-if="!isActive(job.status)" class="btn" to="/envs">Environments ›</RouterLink>
      </div>
    </div>

    <div v-if="job.status === 'FAILED'" class="banner bad">
      The job failed. The last lines of the log below say why; fix the cause and run it again from Environments
      (re-running is safe: every step checks what already exists).
    </div>
    <div v-if="created" class="banner good">
      {{ job.target }} is up. One-time per env on your laptop: add
      <code>127.0.0.1 {{ job.target }}.microecom.local api.{{ job.target }}.microecom.local</code> to <code>/etc/hosts</code>.
    </div>

    <div class="logbox panel">
      <div class="logbar">
        <span class="muted">Log</span>
        <span class="muted small" v-if="!follow">scrolled up — <button class="link" @click="follow = true">follow</button></span>
      </div>
      <pre ref="logEl" @scroll="onScroll" v-html="html || (isActive(job.status) ? 'Starting the runner…' : '(no output)')"></pre>
    </div>
  </template>
</template>

<style scoped>
.back { text-decoration: none; display: inline-block; margin-bottom: 10px; }
.head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; align-items: flex-start; margin-bottom: 14px; }
.target { font-size: 18px; }
.meta { margin-top: 6px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.actions { display: flex; gap: 8px; }
.actions .primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.banner { padding: 10px 14px; border-radius: 10px; margin-bottom: 14px; color: #fff; }
.banner.bad { background: var(--bad); } .banner.good { background: var(--good); }
.banner code { background: rgba(0, 0, 0, .2); padding: 1px 5px; border-radius: 5px; }
.logbox { overflow: hidden; }
.logbar { display: flex; justify-content: space-between; padding: 8px 14px; border-bottom: 1px solid var(--line); }
pre {
  margin: 0; padding: 14px; background: var(--log-bg); color: var(--log-ink); font: 12.5px/1.55 var(--mono);
  max-height: 65vh; overflow: auto; white-space: pre-wrap; word-break: break-word;
}
.link { border: none; background: none; padding: 0; color: var(--acc); text-decoration: underline; }
.small { font-size: 12px; }
.error { color: var(--bad); }
</style>
