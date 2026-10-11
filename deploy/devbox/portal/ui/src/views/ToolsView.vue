<script setup>
import { onMounted, ref } from 'vue'
import { api } from '../api'
import SecretField from '../components/SecretField.vue'

const tools = ref([])
const error = ref('')

onMounted(async () => {
  try { tools.value = await api.tools() } catch (e) { error.value = e.message }
})
</script>

<template>
  <h1>Platform tools</h1>
  <p class="muted lead">The other UIs that make up the devbox, and how to log in. Local dev credentials — read live
    from each tool, so they're always current.</p>
  <p v-if="error" class="error">Couldn't load tools: {{ error }}</p>

  <div class="grid">
    <section v-for="t in tools" :key="t.key" class="panel tool">
      <header>
        <h2>{{ t.name }}</h2>
        <a class="btn primary" :href="t.url" target="_blank" rel="noopener">Open ↗</a>
      </header>
      <p class="muted">{{ t.purpose }}</p>
      <div class="url mono">{{ t.url }}</div>
      <template v-if="t.username || t.password">
        <label>Username</label>
        <SecretField :value="t.username || 'not available'" />
        <label>Password</label>
        <SecretField :value="t.password || 'not available'" :secret="!!t.password" />
      </template>
      <p v-else class="muted nologin">No login needed.</p>
    </section>
  </div>

  <section class="panel help">
    <h2>Opening these by name</h2>
    <p class="muted">The links use ingress hosts. Once per laptop, add to <code>/etc/hosts</code>:</p>
    <SecretField value="127.0.0.1 devbox.microecom.local argocd.microecom.local gitea.microecom.local grafana.microecom.local registry.microecom.local" />
    <p class="muted">and keep the minikube tunnel running (it needs your password once per session, so it's the one step
      the portal can't do for you): <code>sudo -v &amp;&amp; make k8s-tunnel</code>.</p>
  </section>
</template>

<style scoped>
.lead { margin: 4px 0 18px; max-width: 680px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
.tool { padding: 14px 16px; display: flex; flex-direction: column; gap: 6px; }
.tool header { display: flex; justify-content: space-between; align-items: center; }
.tool p { margin: 0 0 4px; }
.tool .primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.url { color: var(--ink2); margin-bottom: 6px; }
label { font-size: 12px; color: var(--ink2); text-transform: uppercase; letter-spacing: .05em; margin-top: 4px; }
.nologin { margin-top: 6px; }
.help { padding: 14px 16px; margin-top: 20px; display: flex; flex-direction: column; gap: 8px; }
.help p { margin: 0; }
.error { color: var(--bad); }
</style>
