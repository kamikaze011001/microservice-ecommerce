<script setup>
import { computed, ref } from 'vue'
import StatusPill from './StatusPill.vue'
import DeployControl from './DeployControl.vue'
import { ago, envUrls } from '../format'

const props = defineProps({
  env: { type: Object, required: true },
  history: { type: Array, default: () => [] },
  tags: { type: Object, default: () => ({}) },
  job: { type: Object, default: null },         // a running job targeting this env
  busy: { type: Boolean, default: false },
})
const emit = defineEmits(['deploy', 'delete'])

const showHistory = ref(false)
const preview = computed(() => props.env.name !== 'prod-like')
const urls = computed(() => envUrls(props.env.name))
const healthy = computed(() => props.env.services.filter((s) => s.sync === 'Synced' && s.health === 'Healthy').length)
const total = computed(() => props.env.services.length)

const short = (img) => img.split(':').pop()
const drifted = (s) => s.desired_tag && s.running_images.length && !s.running_images.some((i) => i.endsWith(':' + s.desired_tag))
</script>

<template>
  <section class="panel env">
    <header>
      <div class="title">
        <h2>{{ env.name }}</h2>
        <span class="pill ghost">{{ preview ? 'preview' : 'baseline' }}</span>
        <span class="pill" :class="healthy === total ? 'good' : 'warn'">{{ healthy }}/{{ total }} healthy</span>
        <RouterLink v-if="job" :to="`/jobs/${job.name}`" class="pill info jobpill">{{ job.title }} — running, watch ›</RouterLink>
      </div>
      <div class="actions">
        <a class="btn" :href="urls.web" target="_blank" rel="noopener">Open storefront ↗</a>
        <a class="btn" :href="urls.api + '/swagger-ui.html'" target="_blank" rel="noopener">API docs ↗</a>
        <button @click="showHistory = !showHistory">{{ showHistory ? 'Hide' : 'Show' }} history</button>
        <button v-if="preview" class="danger" :disabled="busy || !!job" @click="emit('delete', env.name)">Delete</button>
      </div>
    </header>

    <div class="cols" :class="{ withHistory: showHistory }">
      <div class="tablewrap">
        <table>
          <thead>
            <tr><th>Service</th><th>Version (git)</th><th>Running</th><th>Sync</th><th>Health</th><th>Deploy another version</th></tr>
          </thead>
          <tbody>
            <tr v-for="s in env.services" :key="s.name">
              <td class="svc">{{ s.name }}</td>
              <td><code>{{ s.desired_tag || '—' }}</code></td>
              <td>
                <code v-for="img in s.running_images" :key="img" class="img">{{ short(img) }}</code>
                <div v-if="drifted(s)" class="drift">rolling out…</div>
              </td>
              <td><StatusPill :value="s.sync" /></td>
              <td><StatusPill :value="s.health" /></td>
              <td>
                <DeployControl v-if="s.desired_tag" :env="env.name" :service="s.name" :current="s.desired_tag"
                               :tags="tags[s.name] || []" :busy="busy" @deploy="(d) => emit('deploy', d)" />
                <span v-else class="muted">static build</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div v-if="showHistory" class="history">
        <h3>Change history</h3>
        <p class="muted small">Every deploy is a git commit in the env repo — this list is the audit log.</p>
        <ul>
          <li v-for="c in history" :key="c.sha">
            <div>{{ c.message.split('\n')[0] }}</div>
            <div class="meta"><code>{{ c.sha.slice(0, 7) }}</code> · {{ c.author }} · {{ ago(c.date) }}</div>
          </li>
          <li v-if="!history.length" class="muted">No commits yet.</li>
        </ul>
      </div>
    </div>
  </section>
</template>

<style scoped>
.env { margin-bottom: 20px; overflow: hidden; }
header {
  display: flex; flex-wrap: wrap; gap: 10px 16px; justify-content: space-between; align-items: center;
  padding: 12px 16px; border-bottom: 1px solid var(--line);
}
.title { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.actions { display: flex; flex-wrap: wrap; gap: 6px; }
.jobpill { text-decoration: none; }
.cols { display: grid; grid-template-columns: 1fr; }
.cols.withHistory { grid-template-columns: minmax(0, 1fr) 300px; }
.svc { font-weight: 600; white-space: nowrap; }
.img { display: block; }
.drift { color: var(--warn); font-size: 12px; }
.history { border-left: 1px solid var(--line); padding: 12px 14px; max-height: 520px; overflow: auto; background: var(--panel2); }
.history h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .05em; color: var(--ink2); margin: 0 0 4px; }
.history ul { list-style: none; padding: 0; margin: 10px 0 0; font-size: 13px; }
.history li { margin-bottom: 10px; }
.meta { color: var(--ink2); font-size: 12px; }
.small { font-size: 12px; margin: 0; }
@media (max-width: 980px) {
  .cols.withHistory { grid-template-columns: 1fr; }
  .history { border-left: none; border-top: 1px solid var(--line); }
}
</style>
