<script setup>
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import { RouterView, RouterLink, useRouter } from 'vue-router'
import { getSession, logout, getNotifications, getInstance, openMessageSocket } from './api'
import { emitMessage } from './lib/messageBus'
import { fmtBadge } from './utils/format'
import Icon from './components/Icon.vue'
import Avatar from './components/Avatar.vue'

const router = useRouter()
const me = ref(null)
const unread = ref(0)
const unreadMessages = ref(0)
const isDark = ref(localStorage.getItem('theme') !== 'light')
const userMenu = ref(false)
const instance = ref({ name: 'FediVid', description: '' })
let socket = null

let lastUnreadRefresh = 0
const UNREAD_REFRESH_MS = 30_000

function toggleTheme() {
  isDark.value = !isDark.value
  const t = isDark.value ? 'dark' : 'light'
  localStorage.setItem('theme', t)
  document.documentElement.classList.toggle('dark', isDark.value)
}

async function refresh(opts = {}) {
  me.value = await getSession()
  if (!me.value) {
    unread.value = 0
    unreadMessages.value = 0
    return
  }

  const now = Date.now()
  const stale = now - lastUnreadRefresh > UNREAD_REFRESH_MS
  if (opts.force || stale) {
    try {
      unread.value = (await getNotifications(me.value.username)).unseen || 0
      lastUnreadRefresh = now
    } catch {
      unread.value = 0
    }
  }
}

function connectSocket() {
  if (socket) return
  socket = openMessageSocket(onSocketMessage)
}

function closeSocket() {
  if (socket) {
    try { socket.close() } catch { /* ignore */ }
    socket = null
  }
}

function onSocketMessage(msg) {
  emitMessage(msg)
  const onMessages = router.currentRoute.value.path.startsWith('/messages')
  if (!onMessages) {
    unreadMessages.value += 1
  }
}

async function doLogout() {
  closeSocket()
  await logout()
  me.value = null
  userMenu.value = false
  unread.value = 0
  unreadMessages.value = 0
  router.push('/login')
}

onMounted(async () => {
  const inst = await getInstance()
  instance.value = inst
  document.title = inst.name

  await refresh()
  if (me.value) connectSocket()
})

router.afterEach((to) => {
  refresh({ force: to.path === '/notifications' })
  if (to.path.startsWith('/messages')) {
    unreadMessages.value = 0
  }
})

watch(me, (val) => {
  if (val) connectSocket()
  else closeSocket()
})

onBeforeUnmount(closeSocket)
</script>

<template>
  <div style="min-height: 100vh; display: flex; flex-direction: column;">

    <!-- Top bar -->
    <header class="topbar">
      <div class="topbar-inner">
        <RouterLink to="/" class="brand">
          <span class="brand-mark"><Icon name="play" :size="15" /></span>
          <span class="brand-name">{{ instance.name }}</span>
        </RouterLink>

        <nav class="nav-desktop">
          <RouterLink to="/" class="nav-link" :class="{ active: $route.path === '/' }">
            <Icon name="home" :size="16" /> <span>Home</span>
          </RouterLink>
          <RouterLink to="/local" class="nav-link" :class="{ active: $route.path === '/local' }">
            <Icon name="users" :size="16" /> <span>Local</span>
          </RouterLink>
          <RouterLink to="/federated" class="nav-link" :class="{ active: $route.path === '/federated' }">
            <Icon name="repeat" :size="16" /> <span>Federated</span>
          </RouterLink>
          <RouterLink to="/explore" class="nav-link" :class="{ active: $route.path === '/explore' }">
            <Icon name="search" :size="16" /> <span>Explore</span>
          </RouterLink>
        </nav>

        <div class="nav-actions">
          <button @click="toggleTheme" class="icon-btn" :title="isDark ? 'Light mode' : 'Dark mode'">
            <Icon :name="isDark ? 'sun' : 'moon'" :size="18" />
          </button>

          <RouterLink v-if="me" to="/messages" class="icon-btn" title="Messages">
            <Icon name="message" :size="18" />
            <span v-if="unreadMessages" class="badge-dot">{{ fmtBadge(unreadMessages) }}</span>
          </RouterLink>

          <RouterLink v-if="me" to="/notifications" class="icon-btn" title="Notifications">
            <Icon name="bell" :size="18" />
            <span v-if="unread" class="badge-dot">{{ fmtBadge(unread) }}</span>
          </RouterLink>

          <RouterLink v-if="me" to="/upload" class="btn btn-primary btn-sm" style="margin-left: 0.25rem;">
            <Icon name="upload" :size="14" /> <span>Upload</span>
          </RouterLink>

          <template v-if="me">
            <div class="user-menu-wrap">
              <button @click="userMenu = !userMenu" class="user-chip">
                <Avatar :username="me.username" size="sm" />
                <span class="user-name">{{ me.username }}</span>
                <Icon name="menu" :size="12" />
              </button>

              <div v-if="userMenu" class="user-menu" @click="userMenu = false">
                <RouterLink :to="`/users/${me.username}`" class="user-menu-item">
                  <Icon name="user" :size="14" /> My profile
                </RouterLink>
                <RouterLink to="/following" class="user-menu-item">
                  <Icon name="users" :size="14" /> Following
                </RouterLink>
                <RouterLink to="/settings" class="user-menu-item">
                  <Icon name="settings" :size="14" /> Settings
                </RouterLink>
                <RouterLink to="/admin" class="user-menu-item">
                  <Icon name="shield" :size="14" /> Admin
                </RouterLink>
                <RouterLink to="/about" class="user-menu-item">
                  <Icon name="users" :size="14" /> About
                </RouterLink>
                <a href="#" @click.prevent="doLogout" class="user-menu-item">
                  <Icon name="logout" :size="14" /> Log out
                </a>
              </div>
            </div>
          </template>

          <RouterLink v-else to="/login" class="btn btn-primary btn-sm">Log in</RouterLink>
        </div>
      </div>
    </header>

    <!-- Main -->
    <main class="main">
      <RouterView @marked-seen="() => refresh({ force: true })" />
    </main>

    <!-- Mobile bottom nav -->
    <nav v-if="me" class="mobile-nav">
      <RouterLink to="/" class="mobile-link" :class="{ active: $route.path === '/' }">
        <Icon name="home" :size="20" /><span>Home</span>
      </RouterLink>
      <RouterLink to="/local" class="mobile-link" :class="{ active: $route.path === '/local' }">
        <Icon name="users" :size="20" /><span>Local</span>
      </RouterLink>
      <RouterLink to="/federated" class="mobile-link" :class="{ active: $route.path === '/federated' }">
        <Icon name="repeat" :size="20" /><span>Fed</span>
      </RouterLink>
      <RouterLink to="/explore" class="mobile-link" :class="{ active: $route.path === '/explore' }">
        <Icon name="search" :size="20" /><span>Explore</span>
      </RouterLink>
      <RouterLink to="/notifications" class="mobile-link mobile-bell" :class="{ active: $route.path === '/notifications' }">
        <Icon name="bell" :size="20" /><span>Alerts</span>
        <span v-if="unread" class="badge-dot">{{ fmtBadge(unread) }}</span>
      </RouterLink>
    </nav>
  </div>
</template>

<style scoped>
.topbar {
    position: sticky;
    top: 0;
    z-index: 50;
    background: rgba(20, 23, 31, 0.85);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border-bottom: 1px solid #232833;
}
html:not(.dark) .topbar {
    background: rgba(255, 255, 255, 0.85);
    border-color: #e7e7ec;
}

.topbar-inner {
    max-width: 1400px;
    margin: 0 auto;
    padding: 0.7rem 1.5rem;
    display: flex;
    align-items: center;
    gap: 1.5rem;
}

.brand { display: flex; align-items: center; gap: 0.6rem; color: inherit; text-decoration: none; }
.brand:hover { color: #8b5cf6; }
.brand-mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    background: linear-gradient(135deg, #8b5cf6, #d946ef);
    color: #fff;
    border-radius: 8px;
    box-shadow: 0 4px 12px rgba(139, 92, 246, 0.4);
}
.brand-name { font-weight: 800; font-size: 1.15rem; letter-spacing: -0.02em; }

.nav-desktop { display: flex; align-items: center; gap: 0.25rem; flex: 1; }
.nav-link {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.5rem 0.85rem;
    color: #a1a7b3;
    border-radius: 8px;
    font-size: 0.9rem;
    font-weight: 600;
    text-decoration: none;
    transition: background 0.15s, color 0.15s;
}
.nav-link:hover { background: #252a35; color: #f4f4f7; }
.nav-link.active { background: #252a35; color: #f4f4f7; }
html:not(.dark) .nav-link:hover,
html:not(.dark) .nav-link.active { background: #f3f3f6; color: #0e0f14; }

.nav-actions { display: flex; align-items: center; gap: 0.4rem; margin-left: auto; }

.icon-btn {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    background: transparent;
    color: #a1a7b3;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    text-decoration: none;
    transition: background 0.15s, color 0.15s;
}
.icon-btn:hover { background: #252a35; color: #f4f4f7; }
html:not(.dark) .icon-btn:hover { background: #f3f3f6; color: #0e0f14; }

.badge-dot {
    position: absolute;
    top: 2px;
    right: 2px;
    min-width: 16px;
    height: 16px;
    padding: 0 4px;
    background: #ef4444;
    color: white;
    font-size: 0.6rem;
    font-weight: 700;
    border-radius: 9999px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
}

.user-menu-wrap { position: relative; }
.user-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.2rem 0.6rem 0.2rem 0.2rem;
    background: #1c2029;
    color: #f4f4f7;
    border: 1px solid #232833;
    border-radius: 9999px;
    font-family: inherit;
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.15s;
}
.user-chip:hover { border-color: #8b5cf6; }
.user-name { max-width: 8rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.user-menu {
    position: absolute;
    top: calc(100% + 0.5rem);
    right: 0;
    min-width: 180px;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 12px;
    padding: 0.4rem;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
}
.user-menu-item {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.55rem 0.75rem;
    color: #f4f4f7;
    text-decoration: none;
    font-size: 0.88rem;
    font-weight: 500;
    border-radius: 8px;
    cursor: pointer;
}
.user-menu-item:hover { background: #252a35; }

.main {
    flex: 1;
    width: 100%;
    max-width: 1400px;
    margin: 0 auto;
    padding: 2rem 1.5rem 4rem;
}

.mobile-nav { display: none; }

@media (max-width: 768px) {
    .nav-desktop { display: none; }
    .user-name { display: none; }
    .main { padding: 1.25rem 1rem 2rem; }

    .mobile-nav {
        display: flex;
        position: fixed;
        bottom: 0;
        left: 0;
        right: 0;
        background: rgba(20, 23, 31, 0.95);
        backdrop-filter: blur(12px);
        border-top: 1px solid #232833;
        padding: 0.4rem 0 calc(0.4rem + env(safe-area-inset-bottom));
        z-index: 40;
    }
    html:not(.dark) .mobile-nav {
        background: rgba(255, 255, 255, 0.95);
        border-color: #e7e7ec;
    }

    .mobile-link {
        flex: 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 0.15rem;
        padding: 0.5rem 0;
        color: #a1a7b3;
        text-decoration: none;
        font-size: 0.68rem;
        font-weight: 600;
        position: relative;
    }
    .mobile-link.active { color: #8b5cf6; }
}
</style>
