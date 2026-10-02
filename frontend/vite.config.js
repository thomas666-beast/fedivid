import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const backend = env.VITE_BACKEND_URL || 'http://localhost:3000'

  return {
    plugins: [vue(), tailwindcss()],
    server: {
      port: 5173,
      proxy: {
        '/api':         { target: backend, changeOrigin: true, ws: true },
        '/users':       { target: backend, changeOrigin: true },
        '/.well-known': { target: backend, changeOrigin: true },
      },
    },
    build: { outDir: 'dist', emptyOutDir: true },
  }
})
