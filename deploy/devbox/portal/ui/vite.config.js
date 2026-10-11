import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// `npm run dev` talks to a portal on :8282 (e.g. the in-cluster one through
// devbox.microecom.local, or a local `mvn spring-boot:run`).
export default defineConfig({
  plugins: [vue()],
  server: { proxy: { '/api': process.env.PORTAL_URL || 'http://devbox.microecom.local' } },
  build: { outDir: 'dist', emptyOutDir: true },
})
