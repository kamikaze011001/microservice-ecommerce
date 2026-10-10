import { createApp } from 'vue'
import { createRouter, createWebHashHistory } from 'vue-router'
import App from './App.vue'
import EnvironmentsView from './views/EnvironmentsView.vue'
import JobsView from './views/JobsView.vue'
import JobDetailView from './views/JobDetailView.vue'
import PerfView from './views/PerfView.vue'
import ToolsView from './views/ToolsView.vue'
import SettingsView from './views/SettingsView.vue'
import './style.css'

// Hash history: Spring serves one index.html, no server-side route fallback needed.
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/envs' },
    { path: '/envs', component: EnvironmentsView, meta: { title: 'Environments' } },
    { path: '/envs/:env/services/:service/settings', component: SettingsView, props: true, meta: { title: 'Settings' } },
    { path: '/jobs', component: JobsView, meta: { title: 'Jobs' } },
    { path: '/jobs/:name', component: JobDetailView, props: true, meta: { title: 'Job' } },
    { path: '/perf', component: PerfView, meta: { title: 'Perf runs' } },
    { path: '/tools', component: ToolsView, meta: { title: 'Platform tools' } },
  ],
})
router.afterEach((to) => { document.title = `${to.meta.title || 'Devbox'} · Devbox` })

createApp(App).use(router).mount('#app')
