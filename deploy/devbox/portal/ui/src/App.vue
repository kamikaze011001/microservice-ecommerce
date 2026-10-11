<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import { api, isActive } from './api'
import { toast } from './toast'

const links = ref({})
const running = ref(0)
let timer

const TOOLS = [
  ['argocd', 'Argo CD', 'deploy topology & sync'],
  ['gitea', 'Gitea', 'env repo: every change is a commit'],
  ['grafana', 'Grafana', 'metrics & perf dashboards'],
  ['registry', 'Registry', 'image versions'],
]

async function poll() {
  try { running.value = (await api.jobs()).filter((j) => isActive(j.status)).length } catch { /* shown on pages */ }
}

onMounted(async () => {
  try { links.value = (await api.info()).links } catch { /* header links just stay hidden */ }
  poll()
  timer = setInterval(poll, 5000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <div class="shell">
    <aside>
      <div class="brand">
        <span class="logo">◆</span>
        <div><b>Devbox</b><div class="muted small">microecom platform</div></div>
      </div>
      <nav>
        <RouterLink to="/envs">Environments</RouterLink>
        <RouterLink to="/topology">Topology</RouterLink>
        <RouterLink to="/build">Build &amp; deploy</RouterLink>
        <RouterLink to="/jobs">Jobs <span v-if="running" class="pill info">{{ running }} running</span></RouterLink>
        <RouterLink to="/api-testing">API testing</RouterLink>
        <RouterLink to="/perf">Performance</RouterLink>
        <RouterLink to="/tools">Platform tools &amp; logins</RouterLink>
      </nav>
      <div class="tools">
        <div class="label">Platform tools</div>
        <a v-for="[key, name, hint] in TOOLS" :key="key" v-show="links[key]" :href="links[key]"
           target="_blank" rel="noopener" :title="hint">{{ name }} <span class="muted">↗</span></a>
      </div>
    </aside>
    <main><RouterView /></main>
    <div v-if="toast.text" class="toast" :class="toast.kind" role="status">
      <span>{{ toast.text }}</span>
      <button class="x" @click="toast.text = ''" aria-label="Dismiss">✕</button>
    </div>
  </div>
</template>

<style scoped>
.shell { display: grid; grid-template-columns: 220px 1fr; min-height: 100vh; }
aside {
  background: var(--panel); border-right: 1px solid var(--line); padding: 18px 14px;
  position: sticky; top: 0; height: 100vh; display: flex; flex-direction: column; gap: 22px;
}
.brand { display: flex; gap: 10px; align-items: center; }
.logo { color: var(--acc); font-size: 22px; }
.small { font-size: 12px; }
nav { display: flex; flex-direction: column; gap: 2px; }
nav a {
  text-decoration: none; padding: 7px 10px; border-radius: 8px; color: var(--ink2);
  display: flex; justify-content: space-between; align-items: center;
}
nav a:hover { background: var(--panel2); color: var(--ink); }
nav a.router-link-active { background: var(--bg); color: var(--ink); font-weight: 600; }
.tools { display: flex; flex-direction: column; gap: 2px; margin-top: auto; }
.tools .label { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink2); padding: 0 10px 4px; }
.tools a { text-decoration: none; padding: 5px 10px; border-radius: 8px; font-size: 13.5px; }
.tools a:hover { background: var(--panel2); }
main { padding: 24px 28px 60px; min-width: 0; max-width: 1240px; }
.toast {
  position: fixed; right: 16px; bottom: 16px; max-width: 460px; padding: 10px 12px 10px 14px; border-radius: 10px;
  color: #fff; display: flex; gap: 12px; align-items: flex-start; box-shadow: 0 8px 28px rgba(0, 0, 0, .25); z-index: 50;
}
.toast.ok { background: var(--good); } .toast.err { background: var(--bad); }
.toast .x { background: transparent; border: none; color: #fff; padding: 0 2px; }
@media (max-width: 760px) {
  .shell { grid-template-columns: 1fr; }
  aside { position: static; height: auto; flex-direction: row; flex-wrap: wrap; align-items: center; padding: 10px 16px; gap: 12px; }
  nav { flex-direction: row; flex-wrap: wrap; }
  .tools { flex-direction: row; flex-wrap: wrap; margin-top: 0; }
  .tools .label { display: none; }
  main { padding: 16px; }
}
</style>
