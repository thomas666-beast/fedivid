import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './style.css'

const saved = localStorage.getItem('theme') || 'dark'
document.documentElement.classList.toggle('dark', saved === 'dark')

createApp(App).use(router).mount('#app')
