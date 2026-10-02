<script setup>
import { ref, onMounted, onBeforeUnmount, computed } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { getSession, listConversations, openMessageSocket } from '../api'
import { fmtTime } from '../utils/format'
import Icon from '../components/Icon.vue'
import Avatar from '../components/Avatar.vue'

const router = useRouter()
const me = ref(null)
const items = ref([])
const loading = ref(true)
const error = ref(null)
const page = ref(1)
const perPage = 20
let socket = null

const pageCount = computed(() => Math.max(1, Math.ceil(items.value.length / perPage)))
const pagedItems = computed(() => {
  const start = (page.value - 1) * perPage
  return items.value.slice(start, start + perPage)
})

async function load() {
  loading.value = true
  error.value = null
  try {
    const sess = await getSession()
    if (!sess) { router.push('/login'); return }
    me.value = sess
    const data = await listConversations()
    items.value = data.items || []
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

// The backend sends two formats for the same peer:
//   - listConversations: "bob@remote.test" (user@host)
//   - WebSocket sender: "@remote.test/users/bob"
// Normalize to "user@host" so we can match them.
function normalizePeer(s) {
  if (!s) return s
  const m = String(s).match(/^@?([^/@]+)\/users\/([^/]+)$/)
  if (m) return `${m[2]}@${m[1]}`
  return s
}

function onSocketMessage(msg) {
  const peer = normalizePeer(msg.sender)
  const existing = items.value.find(c => c.peer === peer)

  if (existing) {
    existing.last_body = msg.body
    existing.last_at = msg.created_at
    existing.unread = (existing.unread || 0) + 1
    // Bubble to top
    items.value = [existing, ...items.value.filter(c => c !== existing)]
  } else {
    items.value = [{
      peer,
      peer_actor: null,
      last_body: msg.body,
      last_at: msg.created_at,
      unread: 1,
    }, ...items.value]
  }
}

onMounted(async () => {
  await load()
  socket = openMessageSocket(onSocketMessage)
})

onBeforeUnmount(() => {
  if (socket) socket.close()
})
</script>

<template>
  <div class="stack">
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 1rem;">
      <div>
        <h1>Messages</h1>
        <p class="muted">Your conversations.</p>
      </div>
      <RouterLink to="/messages/new" class="btn btn-primary">
        <Icon name="send" :size="16" />
        New message
      </RouterLink>
    </div>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <div v-else-if="items.length === 0" class="empty">
      <Icon name="message" :size="32" style="margin: 0 auto 0.75rem; display: block; color: #6a7180;" />
      <p style="margin: 0;">No messages yet.</p>
      <p class="muted" style="margin: 0.25rem 0 0;">Start a conversation with anyone on the Fediverse.</p>
    </div>

    <template v-else>
      <div class="conv-list">
        <RouterLink
          v-for="c in pagedItems"
          :key="c.peer"
          :to="`/messages/thread/${c.peer}`"
          class="conv-row"
        >
          <Avatar :username="c.peer" size="md" />
          <div class="conv-body">
            <div class="conv-head">
              <span class="conv-from">@{{ c.peer }}</span>
              <span class="conv-time">{{ fmtTime(c.last_at) }}</span>
            </div>
            <p class="conv-preview">{{ c.last_body }}</p>
          </div>
          <span v-if="c.unread" class="badge badge-accent">{{ c.unread }}</span>
        </RouterLink>
      </div>

      <div v-if="pageCount > 1" class="pager">
        <button class="btn btn-sm" :disabled="page === 1" @click="page--">← Prev</button>
        <span class="muted">Page {{ page }} / {{ pageCount }}</span>
        <button class="btn btn-sm" :disabled="page === pageCount" @click="page++">Next →</button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.conv-list { display: flex; flex-direction: column; gap: 0.5rem; }

.conv-row {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 0.9rem 1.1rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
    color: inherit;
    text-decoration: none;
    transition: border-color 0.15s, background 0.15s;
}
.conv-row:hover { border-color: #333a48; background: #181c26; }
html:not(.dark) .conv-row { background: #fff; border-color: #e7e7ec; }

.conv-body { flex: 1; min-width: 0; }
.conv-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    margin-bottom: 0.15rem;
}
.conv-from { font-weight: 700; color: #f4f4f7; }
html:not(.dark) .conv-from { color: #0e0f14; }
.conv-time { font-size: 0.75rem; color: #6a7180; flex-shrink: 0; }
.conv-preview {
    margin: 0;
    color: #a1a7b3;
    font-size: 0.9rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.pager {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 1rem;
    margin-top: 1rem;
}
</style>
