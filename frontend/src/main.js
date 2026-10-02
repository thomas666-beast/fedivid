import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './lib/theme'    // ← initializes the theme (single source of truth)
import './style.css'

createApp(App).use(router).mount('#app')
